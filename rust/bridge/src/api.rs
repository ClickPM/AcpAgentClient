//! 桥命令与事件流（docs/design.md § 3）。R0 只打通 `core_init` / `ping` 与五条事件流的注册；
//! R1 起按 § 3 的命令清单逐条加，返回值一律 JSON `String`。
//! 本模块是 frb 的扫描入口（flutter_rust_bridge.yaml `rust_input: crate::api`），只放要暴露给 Dart 的东西。

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;

use acp_core::core::Core;
use acp_core::events::{EventChannel, EventSink};
use flutter_rust_bridge::frb;

use crate::frb_generated::StreamSink;
use crate::runtime::{core_cell, sinks};

/// 跨桥的错误形状：Dart 侧作为 `BridgeError` 异常抛出。
#[derive(Debug, Clone)]
pub struct BridgeError {
    pub code: String,
    pub message: String,
}

impl BridgeError {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_string(),
            message: message.into(),
        }
    }
}

impl From<acp_core::error::CoreError> for BridgeError {
    fn from(e: acp_core::error::CoreError) -> Self {
        BridgeError::new(e.code(), e.to_string())
    }
}

fn core() -> Result<Arc<Core>, BridgeError> {
    let guard = core_cell()
        .read()
        .map_err(|_| BridgeError::new("poisoned", "core lock poisoned"))?;
    guard
        .as_ref()
        .cloned()
        .ok_or_else(|| BridgeError::new("not_initialized", "call core_init(data_dir) first"))
}

/// panic 不得穿过 FFI（docs/design.md § 12）：frb 自己也会 catch_unwind，这里再兜一层，统一成 `Result`。
fn guarded<T>(f: impl FnOnce() -> Result<T, BridgeError>) -> Result<T, BridgeError> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(payload) => {
            let msg = payload
                .downcast_ref::<&str>()
                .map(|s| (*s).to_string())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "panic without message".to_string());
            Err(BridgeError::new("panic", msg))
        }
    }
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// 初始化核心。`data_dir` 是 docs/design.md § 10 的数据目录（Windows：%APPDATA%/AcpAgentClient）。
/// 幂等：热重启后再次调用只重发一条 `acp/agent_state: core_ready`。返回 JSON `{dataDir, coreVersion}`。
pub fn core_init(data_dir: String) -> Result<String, BridgeError> {
    guarded(|| {
        let sink: Arc<dyn EventSink> = sinks().clone();
        let mut guard = core_cell()
            .write()
            .map_err(|_| BridgeError::new("poisoned", "core lock poisoned"))?;
        let core = match guard.as_ref() {
            Some(existing) => {
                existing.announce_ready();
                existing.clone()
            }
            None => {
                let created = Arc::new(Core::new(data_dir, sink)?);
                *guard = Some(created.clone());
                created
            }
        };
        Ok(core.describe().to_string())
    })
}

/// R0 往返命令：Dart 调过来、核心回 JSON `{pong, sequence, coreVersion}`。
pub async fn ping(echo: String) -> Result<String, BridgeError> {
    guarded(|| Ok(core()?.ping(&echo)?.to_string()))
}

// 五个注册函数都是 `#[frb(sync)]`：frb 的 normal 任务跑在线程池上不保证先后，只有同步注册
// 才能保证 Dart 调 `core_init` 之前 sink 已就位（审查 finding，2026-09-15）。

/// `acp/session_update`：`{agentId, sessionId, update}`，`update` 是 SessionNotification 原样 JSON。
#[frb(sync)]
pub fn session_update_stream(sink: StreamSink<String>) -> Result<(), BridgeError> {
    sinks().register(EventChannel::SessionUpdate, sink);
    Ok(())
}

/// `acp/client_request`：`{agentId, requestId, method, params}`。
#[frb(sync)]
pub fn client_request_stream(sink: StreamSink<String>) -> Result<(), BridgeError> {
    sinks().register(EventChannel::ClientRequest, sink);
    Ok(())
}

/// `acp/agent_state`：连接生命周期；R0 只有 `core_ready`。
#[frb(sync)]
pub fn agent_state_stream(sink: StreamSink<String>) -> Result<(), BridgeError> {
    sinks().register(EventChannel::AgentState, sink);
    Ok(())
}

/// `acp/terminal_output`：`{terminalId, source, bytes}`（R4 才有内容）。
#[frb(sync)]
pub fn terminal_output_stream(sink: StreamSink<String>) -> Result<(), BridgeError> {
    sinks().register(EventChannel::TerminalOutput, sink);
    Ok(())
}

/// `acp/traffic`：脱敏后的原始 JSON-RPC 行（R1 才有内容）。
#[frb(sync)]
pub fn traffic_stream(sink: StreamSink<String>) -> Result<(), BridgeError> {
    sinks().register(EventChannel::Traffic, sink);
    Ok(())
}

/// 未送达（Dart 未订阅或流已关闭）的事件计数，供开发期排查。
#[frb(sync)]
pub fn dropped_event_count() -> u64 {
    sinks().dropped()
}
