//! `initialize` 的能力声明 = docs/design.md § 4 全集。
//! Derived from zed-industries/zed crates/agent_servers/src/acp.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)
//! （`client_capabilities_for_agent`：fs 读写、terminal、auth.terminal、布尔 config option、form / url elicitation、
//! Zed 私约 `terminal_output` / `terminal-auth`，Cursor 追加参数化模型选择器键；本项目另按所有者裁定声明 `plan` 与
//! `session.compaction` 两个 unstable 能力。）

use agent_client_protocol::schema::v1 as acp;

use crate::core::CORE_VERSION;
use crate::meta_keys::outbound;

/// Zed `CURSOR_ID`：registry 里 Cursor 的 agent id。
pub const CURSOR_AGENT_ID: &str = "cursor";
pub const CLIENT_NAME: &str = "AcpAgentClient";

pub fn client_capabilities(agent_id: &str) -> acp::ClientCapabilities {
    let mut meta = acp::Meta::from_iter([
        (outbound::TERMINAL_OUTPUT.to_string(), true.into()),
        (outbound::TERMINAL_AUTH.to_string(), true.into()),
    ]);
    if agent_id == CURSOR_AGENT_ID {
        meta.insert(outbound::PARAMETERIZED_MODEL_PICKER.to_string(), true.into());
    }

    acp::ClientCapabilities::new()
        .fs(acp::FileSystemCapabilities::new().read_text_file(true).write_text_file(true))
        .terminal(true)
        .auth(acp::AuthCapabilities::new().terminal(true))
        .session(
            acp::ClientSessionCapabilities::new()
                .config_options(
                    acp::SessionConfigOptionsCapabilities::new().boolean(acp::BooleanConfigOptionCapabilities::new()),
                )
                .compaction(acp::CompactionCapabilities::new()),
        )
        .plan(acp::PlanCapabilities::new())
        .elicitation(
            acp::ElicitationCapabilities::new()
                .form(acp::ElicitationFormCapabilities::new())
                .url(acp::ElicitationUrlCapabilities::new()),
        )
        .meta(meta)
}

pub fn client_info() -> acp::Implementation {
    acp::Implementation::new(CLIENT_NAME, CORE_VERSION)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试里访问 `_meta` 字段用常量：validate.ps1 只允许 meta 键来自 meta_keys 常量，字段名本身单独成行。
    const META_FIELD: &str = "_meta";

    #[test]
    fn declaration_matches_design_section_4() {
        let v = serde_json::to_value(client_capabilities("dsh-acp-interactive")).expect("json");
        assert_eq!(v["fs"]["readTextFile"], true);
        assert_eq!(v["fs"]["writeTextFile"], true);
        assert_eq!(v["terminal"], true);
        assert_eq!(v["auth"]["terminal"], true);
        assert!(v["session"]["configOptions"]["boolean"].is_object());
        assert!(v["session"]["compaction"].is_object());
        assert!(v["plan"].is_object());
        assert!(v["elicitation"]["form"].is_object());
        assert!(v["elicitation"]["url"].is_object());
        let meta = v[META_FIELD].as_object().expect("meta");
        assert_eq!(meta.len(), 2, "{meta:?}");
        assert_eq!(meta["terminal_output"], true);
        assert_eq!(meta["terminal-auth"], true);

        let cursor = serde_json::to_value(client_capabilities(CURSOR_AGENT_ID)).expect("json");
        let meta = cursor[META_FIELD].as_object().expect("meta");
        assert_eq!(meta.len(), 3);
        assert_eq!(meta["parameterizedModelPicker"], true);
    }
}
