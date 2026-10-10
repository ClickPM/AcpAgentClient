//! 本地索引（docs/design.md § 10）：`%APPDATA%/AcpAgentClient/{sessions.json, projects.json}`。
//! 会话数据归各 agent 自己，本客户端只存索引（agentId + sessionId + 标题 + cwd + 时间 + 消息计数，
//! 另加是否置顶、置顶时间与首条用户指令）与最近项目列表。
//! 两者都走「临时文件 + rename」（AGENTS.md 规则 7），且只写自己的数据目录，不碰任何 agent 的存储。
//!
//! 时间戳一律是 Unix 毫秒（数字）：省掉一个日期格式化依赖，Dart 侧 `DateTime.fromMillisecondsSinceEpoch` 直接吃。
//! 文件读不动 / 不是合法 JSON 时视为空索引并在下一次写入时重建——索引是可再生的缓存，不该让它挡住启动。

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::{Result, SettingsError, write_lock};

/// 最近项目列表的上限（画板 41 的 Recent Projects）。
pub const RECENT_PROJECTS_LIMIT: usize = 20;

/// `sessions.json` 的写锁（见 [`crate::write_lock`]）：多条会话并跑时收轮、发消息、改标题、删除各自写索引，互不等待。
static SESSIONS_WRITES: Mutex<()> = Mutex::new(());

/// `projects.json` 的写锁（见 [`crate::write_lock`]）。
static PROJECTS_WRITES: Mutex<()> = Mutex::new(());

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
    /// 侧栏置顶（画板 46）。没写过的旧索引读回来是 false，落盘时也不写这个默认值。
    #[serde(default, skip_serializing_if = "is_false")]
    pub is_pinned: bool,
    /// 置顶的那一刻（Unix 毫秒）。只在 [SessionEntry::is_pinned] 为真时有值；侧栏 PINNED 区按它倒序。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned_at: Option<i64>,
    /// 这条会话的首条用户指令原文。写一次就不再覆盖（后来的 upsert 省了这个键、或又给了别的文本，都留第一次的）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub first_prompt: Option<String>,
}

fn is_false(value: &bool) -> bool {
    !*value
}

/// `isPinned` 缺键 = 这次没表态，留着原来的；显式 true 且没给 `pinnedAt` 就沿用旧时间，没有旧时间才打现在；
/// 显式 false 清掉置顶时间。`firstPrompt` 非空且原来没有才写入。
fn merge_pin_and_prompt(entry: &mut SessionEntry, existing: &SessionEntry, raw: &serde_json::Value, now: i64) {
    if raw.get("isPinned").and_then(serde_json::Value::as_bool).is_none() {
        entry.is_pinned = existing.is_pinned;
        entry.pinned_at = existing.pinned_at;
    } else if entry.is_pinned {
        entry.pinned_at = raw
            .get("pinnedAt")
            .and_then(serde_json::Value::as_i64)
            .or(existing.pinned_at)
            .or(Some(now));
    } else {
        entry.pinned_at = None;
    }
    entry.first_prompt = match non_empty_prompt(raw) {
        Some(text) if existing.first_prompt.as_ref().is_none_or(String::is_empty) => Some(text),
        _ => existing.first_prompt.clone(),
    };
}

fn non_empty_prompt(raw: &serde_json::Value) -> Option<String> {
    raw.get("firstPrompt")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_string)
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
    Ok(fs::write_atomic(path, text.as_bytes())?)
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

    /// 新增或更新一条（键是 agentId + sessionId）。`created_at` 只在新增时写，`updated_at` 为 0 时打上当前时间。
    ///
    /// 置顶与首条指令不跟着整行替换被抹掉：收轮、改名、补标题都是整行写，而它们不知道这两个字段。
    /// [raw] 是调用方原样的 JSON（解析成 [SessionEntry] 之前）：没有 `isPinned` 这个键就留着原来的置顶态与
    /// `pinnedAt`；显式 `false` 才取消并清掉 `pinnedAt`；`firstPrompt` 只在还没记过、且这次给了非空文本时写一次。
    pub fn upsert_session(&self, mut entry: SessionEntry, raw: &serde_json::Value) -> Result<Vec<SessionEntry>> {
        let _writing = write_lock(&SESSIONS_WRITES);
        let mut index: SessionIndex = load(&self.sessions_path);
        let now = now_ms();
        match index
            .sessions
            .iter_mut()
            .find(|s| s.agent_id == entry.agent_id && s.session_id == entry.session_id)
        {
            Some(existing) => {
                entry.created_at = existing.created_at;
                // 没带 updatedAt（置顶 / 补记）就留着盘上的。带了 0 表示「打成现在」。
                // 带了更小的旧时间也不能把「最后一次发消息」改回去。
                if raw.get("updatedAt").is_none() {
                    entry.updated_at = existing.updated_at;
                } else if entry.updated_at == 0 {
                    entry.updated_at = now;
                } else if entry.updated_at < existing.updated_at {
                    entry.updated_at = existing.updated_at;
                }
                // 置顶 / 补记只带自己的字段。没给的标题、cwd、消息数留着盘上的，避免用镜像里的旧值盖回去。
                if raw.get("title").is_none() {
                    entry.title.clone_from(&existing.title);
                }
                if raw.get("cwd").is_none() {
                    entry.cwd.clone_from(&existing.cwd);
                }
                if raw.get("messageCount").is_none() {
                    entry.message_count = existing.message_count;
                }
                merge_pin_and_prompt(&mut entry, existing, raw, now);
                *existing = entry;
            }
            None => {
                if entry.created_at == 0 {
                    entry.created_at = now;
                }
                if entry.updated_at == 0 {
                    entry.updated_at = now;
                }
                if entry.is_pinned {
                    if entry.pinned_at.is_none() {
                        entry.pinned_at = Some(now);
                    }
                } else {
                    entry.pinned_at = None;
                }
                entry.first_prompt = non_empty_prompt(raw);
                index.sessions.push(entry);
            }
        }
        save(&self.sessions_path, &index)?;
        index.sessions.sort_by_key(|s| std::cmp::Reverse(s.updated_at));
        Ok(index.sessions)
    }

    /// 移除一条（画板 41 的删除确认；向 agent 发 `session/delete` 是 R6 的事）。
    pub fn remove_session(&self, agent_id: &str, session_id: &str) -> Result<Vec<SessionEntry>> {
        let _writing = write_lock(&SESSIONS_WRITES);
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
        let _writing = write_lock(&PROJECTS_WRITES);
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
            is_pinned: false,
            pinned_at: None,
            first_prompt: None,
        }
    }

    fn put(store: &IndexStore, entry: SessionEntry) -> Vec<SessionEntry> {
        let raw = serde_json::to_value(&entry).expect("entry json");
        store.upsert_session(entry, &raw).expect("upsert")
    }

    fn put_raw(store: &IndexStore, raw: serde_json::Value) -> Vec<SessionEntry> {
        let entry: SessionEntry = serde_json::from_value(raw.clone()).expect("parse");
        store.upsert_session(entry, &raw).expect("upsert")
    }

    #[test]
    fn sessions_round_trip_and_sort_by_updated_desc() {
        let dir = temp_dir("sessions");
        let store = IndexStore::new(dir.clone());
        assert!(store.sessions().is_empty());
        assert!(!store.sessions_path.exists(), "read must not create the file");

        put(&store, entry("s1", 100));
        let after = put(&store, entry("s2", 200));
        assert_eq!(after.iter().map(|s| s.session_id.as_str()).collect::<Vec<_>>(), vec!["s2", "s1"]);
        assert!(after.iter().all(|s| s.created_at > 0), "created_at stamped on insert");

        // 更新同一条：createdAt 保持，标题与计数刷新。
        let created = after.iter().find(|s| s.session_id == "s1").expect("s1").created_at;
        let mut renamed = entry("s1", 300);
        renamed.title = Some("改过的标题".into());
        renamed.message_count = 7;
        let after = put(&store, renamed);
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
    fn pin_and_first_prompt_survive_a_row_that_omits_them() {
        let dir = temp_dir("pin");
        let store = IndexStore::new(dir.clone());
        let pinned = put_raw(
            &store,
            serde_json::json!({
                "agentId": "a",
                "sessionId": "s1",
                "title": "t",
                "updatedAt": 100,
                "isPinned": true,
                "pinnedAt": 50,
                "firstPrompt": "  hello\nworld  "
            }),
        );
        let row = pinned.iter().find(|s| s.session_id == "s1").expect("s1");
        assert!(row.is_pinned);
        assert_eq!(row.pinned_at, Some(50));
        assert_eq!(row.first_prompt.as_deref(), Some("hello\nworld"));

        // 收轮 / 改名那种整行：不带这两个键。置顶与首条指令都还在。
        let mut renamed = entry("s1", 300);
        renamed.title = Some("改过".into());
        let after = put(&store, renamed);
        let row = after.iter().find(|s| s.session_id == "s1").expect("s1");
        assert!(row.is_pinned);
        assert_eq!(row.pinned_at, Some(50));
        assert_eq!(row.first_prompt.as_deref(), Some("hello\nworld"));
        assert_eq!(row.title.as_deref(), Some("改过"));

        // 显式取消。首条指令不跟着清。
        let unpinned = put_raw(
            &store,
            serde_json::json!({
                "agentId": "a",
                "sessionId": "s1",
                "title": "改过",
                "updatedAt": 300,
                "isPinned": false
            }),
        );
        let row = unpinned.iter().find(|s| s.session_id == "s1").expect("s1");
        assert!(!row.is_pinned);
        assert_eq!(row.pinned_at, None);
        assert_eq!(row.first_prompt.as_deref(), Some("hello\nworld"));

        // 再给一条别的文本也不覆盖第一次。
        let kept = put_raw(
            &store,
            serde_json::json!({
                "agentId": "a",
                "sessionId": "s1",
                "updatedAt": 400,
                "firstPrompt": "second"
            }),
        );
        let row = kept.iter().find(|s| s.session_id == "s1").expect("s1");
        assert_eq!(row.first_prompt.as_deref(), Some("hello\nworld"));
        assert!(!row.is_pinned, "没带 isPinned 的写入不该把刚取消的置顶写回来");
        assert_eq!(row.updated_at, 400);

        let rolled = put_raw(
            &store,
            serde_json::json!({"agentId": "a", "sessionId": "s1", "updatedAt": 50}),
        );
        assert_eq!(
            rolled.iter().find(|s| s.session_id == "s1").expect("s1").updated_at,
            400,
            "后到的更小 updatedAt 不能把最后一次发消息的时间改回去"
        );

        let pinned_only = put_raw(
            &store,
            serde_json::json!({"agentId": "a", "sessionId": "s1", "isPinned": true, "pinnedAt": 9}),
        );
        let row = pinned_only.iter().find(|s| s.session_id == "s1").expect("s1");
        assert!(row.is_pinned);
        assert_eq!(row.title.as_deref(), Some("改过"), "缺 title 的置顶写入留着盘上的标题");
        assert_eq!(row.message_count, 2);
        assert_eq!(row.updated_at, 400);

        let stamped = put_raw(
            &store,
            serde_json::json!({"agentId": "a", "sessionId": "s2", "updatedAt": 10, "isPinned": true}),
        );
        let s2 = stamped.iter().find(|s| s.session_id == "s2").expect("s2");
        assert!(s2.is_pinned);
        assert!(s2.pinned_at.is_some_and(|at| at > 0), "没给 pinnedAt 时打上当前时间");
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
        let after = put(&store, entry("s1", 10));
        assert_eq!(after.len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 多条会话同时写索引（并跑的会话各自收轮、中途又删掉一条）：新写的一条都不丢，删掉的一条都不复活（iteration-10）。
    #[test]
    fn concurrent_writes_to_different_sessions_all_land() {
        const WRITERS: usize = 8;
        const EACH: usize = 8;
        let dir = temp_dir("concurrent");
        let store = IndexStore::new(dir.clone());
        for w in 0..WRITERS {
            put(&store, entry(&format!("old-{w}"), 1));
        }
        let start = std::sync::Barrier::new(WRITERS);
        std::thread::scope(|s| {
            for w in 0..WRITERS {
                let (store, start) = (&store, &start);
                s.spawn(move || {
                    start.wait();
                    for i in 0..EACH {
                        put(store, entry(&format!("new-{w}-{i}"), 100));
                        if i == EACH / 2 {
                            store.remove_session("a", &format!("old-{w}")).expect("remove");
                        }
                    }
                });
            }
        });
        let ids: Vec<String> = store.sessions().into_iter().map(|s| s.session_id).collect();
        assert_eq!(ids.len(), WRITERS * EACH, "丢了条目或删掉的复活了：{ids:?}");
        assert!(ids.iter().all(|id| id.starts_with("new-")), "删掉的会话复活了：{ids:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn concurrent_project_opens_all_land() {
        const WRITERS: usize = 8;
        const _: () = assert!(WRITERS <= RECENT_PROJECTS_LIMIT);
        let dir = temp_dir("projects-concurrent");
        let store = IndexStore::new(dir.clone());
        let projects: Vec<PathBuf> = (0..WRITERS).map(|w| dir.join(format!("proj-{w}"))).collect();
        for p in &projects {
            std::fs::create_dir_all(p).expect("mkdir");
        }
        let start = std::sync::Barrier::new(WRITERS);
        std::thread::scope(|s| {
            for p in &projects {
                let (store, start) = (&store, &start);
                s.spawn(move || {
                    start.wait();
                    for _ in 0..8 {
                        store.open_project(p).expect("open");
                    }
                });
            }
        });
        assert_eq!(store.projects().len(), WRITERS);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
