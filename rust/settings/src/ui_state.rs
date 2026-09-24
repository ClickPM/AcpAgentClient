//! 窗口 UI 状态（docs/design.md § 10）：`%APPDATA%/AcpAgentClient/ui-state.json`。
//!
//! 只存机器态——两栏被拖出来的宽度（画板 04 的分栏把手，所有者裁定 2026-09-16）与文件面板树列的宽度 / 收起态
//! （画板 60，所有者裁定 2026-09-17）。
//! 不进 `settings.json`：那份是用户手写的配置（`agent_servers` 与 Zed 同形），不该被窗口操作改写。
//! 走「临时文件 + rename」（CLAUDE.md 规则 7）；读不动 / 不是合法 JSON 时按缺省，不挡启动。
//!
//! 字段一律 `Option`：缺省宽度是设计 token（`lib/theme/tokens.dart`），**不在这里再写一份**；
//! 没存过就返回 null，由前端落到 token 上。夹取范围同理，也在前端。

use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::{Result, SettingsError, write_lock};

/// `ui-state.json` 的写锁（见 [`crate::write_lock`]）：[`UiStateStore::merge`] 是合并写，两次拖不同的把手不能互相盖掉。
static UI_STATE_WRITES: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct UiState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sidebar_width: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub right_panel_width: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub files_tree_width: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub files_tree_collapsed: Option<bool>,
}

/// 非有限数与非正数一律丢掉：宁可回落到 token，也不把 NaN 写进文件。
fn sane(value: Option<f64>) -> Option<f64> {
    value.filter(|v| v.is_finite() && *v > 0.0)
}

#[derive(Debug, Clone)]
pub struct UiStateStore {
    pub path: PathBuf,
}

impl UiStateStore {
    pub fn new(data_dir: PathBuf) -> Self {
        Self { path: data_dir.join("ui-state.json") }
    }

    pub fn load(&self) -> UiState {
        let state: UiState = std::fs::read_to_string(&self.path)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        UiState {
            sidebar_width: sane(state.sidebar_width),
            right_panel_width: sane(state.right_panel_width),
            files_tree_width: sane(state.files_tree_width),
            files_tree_collapsed: state.files_tree_collapsed,
        }
    }

    /// 合并写：只覆盖 `patch` 里给到的字段，没给的保留原值。返回落盘后的全量状态。
    pub fn merge(&self, patch: UiState) -> Result<UiState> {
        let _writing = write_lock(&UI_STATE_WRITES);
        let mut state = self.load();
        if let Some(width) = sane(patch.sidebar_width) {
            state.sidebar_width = Some(width);
        }
        if let Some(width) = sane(patch.right_panel_width) {
            state.right_panel_width = Some(width);
        }
        if let Some(width) = sane(patch.files_tree_width) {
            state.files_tree_width = Some(width);
        }
        if let Some(collapsed) = patch.files_tree_collapsed {
            state.files_tree_collapsed = Some(collapsed);
        }
        let text = serde_json::to_string_pretty(&state).map_err(|e| SettingsError::Json(e.to_string()))?;
        fs::write_atomic(&self.path, text.as_bytes())?;
        Ok(state)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 与 index.rs 的测试同一套自建临时目录：不引 tempfile（规则 1 的通用库清单里没有）。
    fn store(tag: &str) -> UiStateStore {
        let dir = std::env::temp_dir().join(format!("acp-ui-state-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("mkdir");
        UiStateStore::new(dir)
    }

    #[test]
    fn missing_file_is_all_none() {
        assert_eq!(store("missing").load(), UiState::default());
    }

    #[test]
    fn merge_keeps_the_field_that_was_not_given() {
        let store = store("merge");
        store.merge(UiState { sidebar_width: Some(320.0), ..UiState::default() }).expect("merge");
        let state = store.merge(UiState { right_panel_width: Some(640.0), ..UiState::default() }).expect("merge");
        assert_eq!(state.sidebar_width, Some(320.0));
        assert_eq!(state.right_panel_width, Some(640.0));
        let state = store.merge(UiState { files_tree_collapsed: Some(true), ..UiState::default() }).expect("merge");
        assert_eq!(state.sidebar_width, Some(320.0));
        assert_eq!(state.files_tree_collapsed, Some(true));
        assert_eq!(store.load(), state);
    }

    #[test]
    fn corrupt_file_reads_as_default_and_is_rebuilt() {
        let store = store("corrupt");
        std::fs::write(&store.path, b"{ not json").expect("write");
        assert_eq!(store.load(), UiState::default());
        let state = store.merge(UiState { sidebar_width: Some(300.0), ..UiState::default() }).expect("merge");
        assert_eq!(state.sidebar_width, Some(300.0));
    }

    #[test]
    fn nonsense_widths_are_dropped_not_written() {
        let store = store("nonsense");
        let patch = UiState {
            sidebar_width: Some(f64::NAN),
            right_panel_width: Some(-1.0),
            files_tree_width: Some(0.0),
            ..UiState::default()
        };
        assert_eq!(store.merge(patch).expect("merge"), UiState::default());
        let junk = br#"{"sidebarWidth": 0, "rightPanelWidth": 1e400, "filesTreeWidth": -3}"#;
        std::fs::write(&store.path, junk).expect("write");
        assert_eq!(store.load(), UiState::default());
    }

    /// 四个字段各由一个线程同时合并写一次：哪一个都不能被别人的旧快照盖回 null（iteration-10）。
    /// 每轮从空文件起、各写一次就核对——同一个线程反复写的话，中途被盖掉的值会被它自己下一次写补回来，测不出来。
    #[test]
    fn concurrent_merges_of_different_fields_all_land() {
        let store = store("concurrent");
        let patches = [
            UiState { sidebar_width: Some(300.0), ..UiState::default() },
            UiState { right_panel_width: Some(600.0), ..UiState::default() },
            UiState { files_tree_width: Some(200.0), ..UiState::default() },
            UiState { files_tree_collapsed: Some(true), ..UiState::default() },
        ];
        let all = UiState {
            sidebar_width: Some(300.0),
            right_panel_width: Some(600.0),
            files_tree_width: Some(200.0),
            files_tree_collapsed: Some(true),
        };
        for round in 0..32 {
            let _ = std::fs::remove_file(&store.path);
            let start = std::sync::Barrier::new(patches.len());
            std::thread::scope(|s| {
                for patch in patches {
                    let (store, start) = (&store, &start);
                    s.spawn(move || {
                        start.wait();
                        store.merge(patch).expect("merge");
                    });
                }
            });
            assert_eq!(store.load(), all, "第 {round} 轮");
        }
    }
}
