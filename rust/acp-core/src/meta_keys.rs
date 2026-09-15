//! `_meta` 键的唯一出处（CLAUDE.md 规则 2；清单在 docs/design.md § 4）。
//! `rust/` 里任何 `_meta` 键都必须引用这里的常量，`scripts/validate.ps1` 会核对：
//! 本文件的常量 ⊆ § 4 清单，且其他文件的 `_meta` 行不得携带字符串字面量。

/// 我们**发出**的 `_meta`（initialize 的 clientCapabilities）。
pub mod outbound {
    /// Zed 私约：dsh 读它决定是否公布终端能力。
    pub const TERMINAL_OUTPUT: &str = "terminal_output";
    /// Zed 私约：旧版 terminal auth 兼容标记。
    pub const TERMINAL_AUTH: &str = "terminal-auth";
    /// 仅对 Cursor 追加：参数化模型选择器。
    pub const PARAMETERIZED_MODEL_PICKER: &str = "parameterizedModelPicker";
}

/// 前端**读取**的入站 `_meta` 识别键（子代理卡分组，只按键存在判，不按 agent 名判）。
pub mod inbound {
    pub const CLAUDE_CODE_PARENT_TOOL_USE_ID: &str = "claudeCode.parentToolUseId";
    pub const CLAUDE_CODE_SUBAGENT: &str = "claudeCode.subagent";
    pub const CLAUDE_CODE_TOOL_NAME: &str = "claudeCode.toolName";
    pub const DSH_SUBAGENT: &str = "dsh_subagent";
}
