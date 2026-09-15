//! 桥的进程内状态：五条事件流的 Dart 端 sink 与唯一的 `Core` 实例。
//! 放在 `api` 模块之外，frb 不会把这些类型扫成 Dart 侧的 opaque 类型。

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock, RwLock};

use acp_core::core::Core;
use acp_core::events::{EventChannel, EventSink};

use crate::frb_generated::StreamSink;

/// 五条事件流的 Dart 端 sink。Dart 先订阅再 `core_init`；未订阅时到达的事件丢弃并计数。
#[derive(Default)]
pub(crate) struct Sinks {
    session_update: RwLock<Option<StreamSink<String>>>,
    client_request: RwLock<Option<StreamSink<String>>>,
    agent_state: RwLock<Option<StreamSink<String>>>,
    terminal_output: RwLock<Option<StreamSink<String>>>,
    traffic: RwLock<Option<StreamSink<String>>>,
    dropped: AtomicU64,
}

impl Sinks {
    fn slot(&self, channel: EventChannel) -> &RwLock<Option<StreamSink<String>>> {
        match channel {
            EventChannel::SessionUpdate => &self.session_update,
            EventChannel::ClientRequest => &self.client_request,
            EventChannel::AgentState => &self.agent_state,
            EventChannel::TerminalOutput => &self.terminal_output,
            EventChannel::Traffic => &self.traffic,
        }
    }

    pub(crate) fn register(&self, channel: EventChannel, sink: StreamSink<String>) {
        let slot = self.slot(channel);
        match slot.write() {
            Ok(mut guard) => *guard = Some(sink),
            Err(poisoned) => *poisoned.into_inner() = Some(sink),
        }
    }

    pub(crate) fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }
}

impl EventSink for Sinks {
    fn emit(&self, channel: EventChannel, payload: String) {
        let slot = self.slot(channel);
        let delivered = match slot.read() {
            Ok(guard) => match guard.as_ref() {
                Some(sink) => sink.add(payload).is_ok(),
                None => false,
            },
            Err(_) => false,
        };
        if !delivered {
            self.dropped.fetch_add(1, Ordering::Relaxed);
        }
    }
}

pub(crate) fn sinks() -> &'static Arc<Sinks> {
    static SINKS: OnceLock<Arc<Sinks>> = OnceLock::new();
    SINKS.get_or_init(|| Arc::new(Sinks::default()))
}

pub(crate) fn core_cell() -> &'static RwLock<Option<Arc<Core>>> {
    static CORE: OnceLock<RwLock<Option<Arc<Core>>>> = OnceLock::new();
    CORE.get_or_init(|| RwLock::new(None))
}
