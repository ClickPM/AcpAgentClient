//! ACP 客户端核心（docs/design.md § 1）：官方 rust-sdk v2 的 Client 角色，每个 agent 一条 stdio 连接、多会话复用。
//!
//! - [`core::Core`]：runtime、数据目录、settings、终端表、agent 连接表与全部对外命令；
//! - [`agent::AgentConnection`]：一条连接的拉起 / initialize / 会话命令 / agent → client 请求队列 / traffic tap / 退出；
//! - [`capabilities`]、[`terminal_auth`]、[`command`]：能力声明、terminal 型认证、子进程拉起（Windows 细节）；
//! - [`redact`]：`acp/traffic` 脱敏；[`events`]：五条事件流；[`meta_keys`]：`_meta` 键的唯一出处。
//!
//! 对外 API 统一返回 [`error::Result`]，不让 panic 穿过 FFI。

pub mod agent;
pub mod capabilities;
pub mod command;
pub mod core;
pub mod error;
pub mod events;
pub mod log;
pub mod meta_keys;
pub mod redact;
pub mod registry_ops;
pub mod terminal_auth;
