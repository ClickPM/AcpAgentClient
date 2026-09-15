//! ACP 客户端核心（docs/design.md § 1）：官方 rust-sdk v2 的 Client 角色，每个 agent 一条 stdio 连接。
//!
//! R0 只有骨架：`Core`（tokio runtime + 事件出口 + `ping`）、事件通道枚举、错误边界、`_meta` 键常量。
//! R1 在此之上接 `agent_connect` / `session_new` / `session_prompt` 等主线。
//! 对外 API 统一返回 [`error::Result`]，不让 panic 穿过 FFI。

pub mod core;
pub mod error;
pub mod events;
pub mod meta_keys;
