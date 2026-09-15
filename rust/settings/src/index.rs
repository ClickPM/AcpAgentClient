//! 本地索引（docs/design.md § 10）：`%APPDATA%/AcpAgentClient/{sessions.json, projects.json}`。
//! 会话数据归各 agent 自己，本客户端只存索引（agentId + sessionId + 标题 + cwd + 时间 + 消息计数）与最近项目列表。
//! 两者都走「临时文件 + rename」（CLAUDE.md 规则 7），且只写自己的数据目录，不碰任何 agent 的存储。
//!
//! 时间戳一律是 Unix 毫秒（数字）：省掉一个日期格式化依赖，Dart 侧 `DateTime.fromMillisecondsSinceEpoch` 直接吃。
//! 文件读不动 / 不是合法 JSON 时视为空索引并在下一次写入时重建——索引是可再生的缓存，不该让它挡住启动。

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::{Result, SettingsError, write_atomic};

/// 最近项目列表的上限（画板 41 的 Recent Projects）。
pub const RECENT_PROJECTS_LIMIT: usize = 20;

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 侧栏一条会话（画板 01 / 04）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionEntry {
    pub agent_id: String,
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default)]
    pub created_at: i64,
    #[serde(default)]
    pub updated_at: i64,
    #[serde(default)]
    pub message_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct SessionIndex {
    #[serde(default)]
    pub sessions: Vec<SessionEntry>,
}

/// 一个项目 = 一个本地目录（所有者裁定 2026-09-15）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectEntry {
    pub path: String,
    pub name: String,
    #[serde(default)]
    pub opened_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ProjectIndex {
    #[serde(default)]
    pub projects: Vec<ProjectEntry>,
}

/// 目录名（`workspace_open` 的默认项目名）。路径以分隔符结尾或是盘根时回落到原路径。
pub fn project_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| path.to_string_lossy().into_owned())
}

#[derive(Debug, Clone)]
pub struct IndexStore {
    pub sessions_path: PathBuf,
    pub projects_path: PathBuf,
}

fn load<T: Default + for<'de> Deserialize<'de>>(path: &Path) -> T {
    match std::fs::read_to_string(path) {
        Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
        Err(_) => T::default(),
    }
}

fn save<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let text = serde_json::to_string_pretty(value).map_err(|e| SettingsError::Json(e.to_string()))?;
    write_atomic(path, text.as_bytes())
}

impl IndexStore {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            sessions_path: data_dir.join("sessions.json"),
            projects_path: data_dir.join("projects.json"),
        }
    }

    // ---- 会话索引

    /// 按 `updatedAt` 倒序（侧栏顺序）。
    pub fn sessions(&self) -> Vec<SessionEntry> {
        let mut index: SessionIndex = load(&self.sessions_path);
        index.sessions.sort_by_key(|s| std::cmp::Reverse(s.updated_at));
        index.sessions
    }

    /// 新增或更新一条（键是 agentId + sessionId）。`created_at` 只在新增时写，`updated_at` 每次都刷新。
    pub fn upsert_session(&self, mut entry: SessionEntry) -> Result<Vec<SessionEntry>> {
        let mut index: SessionIndex = load(&self.sessions_path);
        let now = now_ms();
        if entry.updated_at == 0 {
            entry.updated_at = now;
        }
        match index
            .sessions
            .iter_mut()
            .find(|s| s.agent_id == entry.agent_id && s.session_id == entry.session_id)
        {
            Some(existing) => {
                entry.created_at = existing.created_at;
                *existing = entry;
            }
            None => {
                if entry.created_at == 0 {
                    entry.created_at = now;
                }
                index.sessions.push(entry);
            }
        }
        save(&self.sessions_path, &index)?;
        index.sessions.sort_by_key(|s| std::cmp::Reverse(s.updated_at));
        Ok(index.sessions)
    }

    /// 移除一条（画板 41 的删除确认；向 agent 发 `session/delete` 是 R6 的事）。
    pub fn remove_session(&self, agent_id: &str, session_id: &str) -> Result<Vec<SessionEntry>> {
        let mut index: SessionIndex = load(&self.sessions_path);
        index.sessions.retain(|s| !(s.agent_id == agent_id && s.session_id == session_id));
        save(&self.sessions_path, &index)?;
        index.sessions.sort_by_key(|s| std::cmp::Reverse(s.updated_at));
        Ok(index.sessions)
    }

    // ---- 最近项目

    /// 按 `openedAt` 倒序。
    pub fn projects(&self) -> Vec<ProjectEntry> {
        let mut index: ProjectIndex = load(&self.projects_path);
        index.projects.sort_by_key(|p| std::cmp::Reverse(p.opened_at));
        index.projects
    }

    /// 打开一个目录：校验它存在且是目录，写进最近列表（去重、置顶、截断到 [`RECENT_PROJECTS_LIMIT`]）。
    pub fn open_project(&self, path: &Path) -> Result<(ProjectEntry, Vec<ProjectEntry>)> {
        if !path.is_dir() {
            return Err(SettingsError::Io(format!("{} is not a directory", path.display())));
        }
        let entry = ProjectEntry {
            path: path.to_string_lossy().into_owned(),
            name: project_name(path),
            opened_at: now_ms(),
        };
        let mut index: ProjectIndex = load(&self.projects_path);
        index.projects.retain(|p| p.path != entry.path);
        index.projects.insert(0, entry.clone());
        index.projects.truncate(RECENT_PROJECTS_LIMIT);
        save(&self.projects_path, &index)?;
        Ok((entry, index.projects))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("acp-index-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("mkdir");
        dir
    }

    fn entry(session: &str, updated: i64) -> SessionEntry {
        SessionEntry {
            agent_id: "a".into(),
            session_id: session.into(),
            title: Some(format!("t-{session}")),
            cwd: Some("D:/ws".into()),
            created_at: 0,
            updated_at: updated,
            message_count: 2,
        }
    }

    #[test]
    fn sessions_round_trip_and_sort_by_updated_desc() {
        let dir = temp_dir("sessions");
        let store = IndexStore::new(dir.clone());
        assert!(store.sessions().is_empty());
        assert!(!store.sessions_path.exists(), "read must not create the file");

        store.upsert_session(entry("s1", 100)).expect("upsert");
        let after = store.upsert_session(entry("s2", 200)).expect("upsert");
        assert_eq!(after.iter().map(|s| s.session_id.as_str()).collect::<Vec<_>>(), vec!["s2", "s1"]);
        assert!(after.iter().all(|s| s.created_at > 0), "created_at stamped on insert");

        // 更新同一条：createdAt 保持，标题与计数刷新。
        let created = after.iter().find(|s| s.session_id == "s1").expect("s1").created_at;
        let mut renamed = entry("s1", 300);
        renamed.title = Some("改过的标题".into());
        renamed.message_count = 7;
        let after = store.upsert_session(renamed).expect("upsert");
        let s1 = after.iter().find(|s| s.session_id == "s1").expect("s1");
        assert_eq!(s1.created_at, created);
        assert_eq!(s1.title.as_deref(), Some("改过的标题"));
        assert_eq!(s1.message_count, 7);
        assert_eq!(after.first().expect("first").session_id, "s1");

        let after = store.remove_session("a", "s1").expect("remove");
        assert_eq!(after.len(), 1);
        // 没有残留临时文件。
        assert!(
            std::fs::read_dir(&dir)
                .expect("dir")
                .filter_map(|e| e.ok())
                .all(|e| !e.file_name().to_string_lossy().contains(".tmp-")),
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn open_project_dedupes_and_requires_a_directory() {
        let dir = temp_dir("projects");
        let store = IndexStore::new(dir.clone());
        let a = dir.join("proj-a");
        let b = dir.join("proj-b");
        std::fs::create_dir_all(&a).expect("mkdir");
        std::fs::create_dir_all(&b).expect("mkdir");

        let (entry, list) = store.open_project(&a).expect("open");
        assert_eq!(entry.name, "proj-a");
        assert_eq!(list.len(), 1);
        store.open_project(&b).expect("open");
        let (_, list) = store.open_project(&a).expect("reopen");
        assert_eq!(list.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), vec!["proj-a", "proj-b"], "重开置顶且不重复");

        let missing = dir.join("nope");
        assert!(store.open_project(&missing).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_index_is_treated_as_empty_and_rebuilt() {
        let dir = temp_dir("corrupt");
        let store = IndexStore::new(dir.clone());
        std::fs::write(&store.sessions_path, "{ not json").expect("write");
        assert!(store.sessions().is_empty());
        let after = store.upsert_session(entry("s1", 10)).expect("upsert rebuilds");
        assert_eq!(after.len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
