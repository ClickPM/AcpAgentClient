//! 核心 → 前端的五条事件流（docs/design.md § 3「事件」）。payload 一律是 JSON 字符串。

/// 事件通道，与 § 3 的事件名一一对应。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EventChannel {
    /// `acp/session_update`
    SessionUpdate,
    /// `acp/client_request`
    ClientRequest,
    /// `acp/agent_state`
    AgentState,
    /// `acp/terminal_output`
    TerminalOutput,
    /// `acp/traffic`
    Traffic,
}

impl EventChannel {
    pub const ALL: [EventChannel; 5] = [
        EventChannel::SessionUpdate,
        EventChannel::ClientRequest,
        EventChannel::AgentState,
        EventChannel::TerminalOutput,
        EventChannel::Traffic,
    ];

    /// 契约里的事件名。
    pub fn name(self) -> &'static str {
        match self {
            EventChannel::SessionUpdate => "acp/session_update",
            EventChannel::ClientRequest => "acp/client_request",
            EventChannel::AgentState => "acp/agent_state",
            EventChannel::TerminalOutput => "acp/terminal_output",
            EventChannel::Traffic => "acp/traffic",
        }
    }
}

/// 事件出口。桥层实现为 frb `StreamSink`，`acp-smoke` 实现为 stdout JSON 行。
/// 实现必须非阻塞：核心在 tokio 线程上调用它。
pub trait EventSink: Send + Sync {
    fn emit(&self, channel: EventChannel, payload: String);
}

/// 收集事件的测试用 sink。
#[derive(Debug, Default)]
pub struct RecordingSink {
    events: std::sync::Mutex<Vec<(EventChannel, String)>>,
}

impl RecordingSink {
    pub fn take(&self) -> Vec<(EventChannel, String)> {
        match self.events.lock() {
            Ok(mut guard) => std::mem::take(&mut *guard),
            Err(poisoned) => std::mem::take(&mut *poisoned.into_inner()),
        }
    }
}

impl EventSink for RecordingSink {
    fn emit(&self, channel: EventChannel, payload: String) {
        match self.events.lock() {
            Ok(mut guard) => guard.push((channel, payload)),
            Err(poisoned) => poisoned.into_inner().push((channel, payload)),
        }
    }
}
