//! sidecar 侧 `_meta` 键的唯一出处（CLAUDE.md 规则 2；清单在 docs/design.md § 4）。
//!
//! 和 `rust/acp-core/src/meta_keys.rs` 是同一份清单的两个副本 —— sidecar 是独立 workspace，
//! 依赖不到 `acp-core`。`scripts/validate.ps1` 对两处用同一条规则核对：本文件的常量 ⊆ § 4 清单，
//! 且其他文件的 `_meta` 行不得携带字符串字面量。

/// 我们**发出**的 `_meta`：终端 provider 通道（docs/design.md § 4）。
/// Zed 作为客户端时读的就是这三键（`agent_servers/acp.rs` 的 pre/post-handle），前端投影层同样只按键存在处理。
pub const TERMINAL_INFO: &str = "terminal_info";
pub const TERMINAL_OUTPUT: &str = "terminal_output";
pub const TERMINAL_EXIT: &str = "terminal_exit";

/// 三键共有的字段名。
pub const TERMINAL_ID_FIELD: &str = "terminal_id";
