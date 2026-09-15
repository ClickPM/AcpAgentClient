//! frb cdylib：Flutter 宿主进程内加载的 Rust 核心入口（docs/design.md § 1 / § 3）。
//! 桥上只传 JSON `String`；协议类型不做 Dart 镜像。

pub mod api;
mod runtime;
// frb 生成物是 CLAUDE.md 规则 6 的唯一例外（extern "C" 边界由生成器负责），按模块放行。
#[allow(unsafe_code, clippy::all, clippy::unwrap_used, clippy::unimplemented, clippy::todo)]
mod frb_generated;
