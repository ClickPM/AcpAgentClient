//! 窗口 UI 状态（docs/design.md § 10）：`%APPDATA%/AcpAgentClient/ui-state.json`。
//!
//! 只存机器态——目前是两栏被拖出来的宽度（画板 04 的分栏把手，所有者裁定 2026-09-16）。
//! 不进 `settings.json`：那份是用户手写的配置（`agent_servers` 与 Zed 同形），不该被窗口操作改写。
//! 走「临时文件 + rename」（CLAUDE.md 规则 7）；读不动 / 不是合法 JSON 时按缺省，不挡启动。
//!
//! 字段一律 `Option`：缺省宽度是设计 token（`lib/theme/tokens.dart`），**不在这里再写一份**；
//! 没存过就返回 null，由前端落到 token 上。夹取范围同理，也在前端。

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::{Result, SettingsError, write_atomic};

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct UiState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sidebar_width: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub right_panel_width: Option<f64>,
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
        UiState { sidebar_width: sane(state.sidebar_width), right_panel_width: sane(state.right_panel_width) }
    }

    /// 合并写：只覆盖 `patch` 里给到的字段，没给的保留原值。返回落盘后的全量状态。
    pub fn merge(&self, patch: UiState) -> Result<UiState> {
        let mut state = self.load();
        if let Some(width) = sane(patch.sidebar_width) {
            state.sidebar_width = Some(width);
        }
        if let Some(width) = sane(patch.right_panel_width) {
            state.right_panel_width = Some(width);
        }
        let text = serde_json::to_string_pretty(&state).map_err(|e| SettingsError::Json(e.to_string()))?;
        write_atomic(&self.path, text.as_bytes())?;
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
        store.merge(UiState { sidebar_width: Some(320.0), right_panel_width: None }).expect("merge");
        let state = store.merge(UiState { sidebar_width: None, right_panel_width: Some(640.0) }).expect("merge");
        assert_eq!(state.sidebar_width, Some(320.0));
        assert_eq!(state.right_panel_width, Some(640.0));
        assert_eq!(store.load(), state);
    }

    #[test]
    fn corrupt_file_reads_as_default_and_is_rebuilt() {
        let store = store("corrupt");
        std::fs::write(&store.path, b"{ not json").expect("write");
        assert_eq!(store.load(), UiState::default());
        let state = store.merge(UiState { sidebar_width: Some(300.0), right_panel_width: None }).expect("merge");
        assert_eq!(state.sidebar_width, Some(300.0));
    }

    #[test]
    fn nonsense_widths_are_dropped_not_written() {
        let store = store("nonsense");
        let state = store.merge(UiState { sidebar_width: Some(f64::NAN), right_panel_width: Some(-1.0) }).expect("merge");
        assert_eq!(state, UiState::default());
        std::fs::write(&store.path, br#"{"sidebarWidth": 0, "rightPanelWidth": 1e400}"#).expect("write");
        assert_eq!(store.load(), UiState::default());
    }
}
