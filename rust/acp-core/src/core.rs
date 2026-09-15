//! `Core`：进程内唯一的核心实例。持有 tokio runtime、数据目录与事件出口。
//! R0 只提供 `ping` 与 `core_ready` 事件；R1 起在这里挂 agent 连接表。

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{Value, json};

use crate::error::{CoreError, Result};
use crate::events::{EventChannel, EventSink};

pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

pub struct Core {
    data_dir: PathBuf,
    sink: Arc<dyn EventSink>,
    runtime: tokio::runtime::Runtime,
    ping_seq: AtomicU64,
}

impl std::fmt::Debug for Core {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Core")
            .field("data_dir", &self.data_dir)
            .finish_non_exhaustive()
    }
}

impl Core {
    /// 建核心：校验并创建数据目录（docs/design.md § 10 的布局由各子 crate 在自己的轮次补齐），
    /// 起 tokio 多线程 runtime，然后发一条 `acp/agent_state: core_ready`。
    pub fn new(data_dir: impl AsRef<Path>, sink: Arc<dyn EventSink>) -> Result<Self> {
        let data_dir = data_dir.as_ref();
        if data_dir.as_os_str().is_empty() || !data_dir.is_absolute() {
            return Err(CoreError::InvalidDataDir(
                data_dir.to_string_lossy().into_owned(),
            ));
        }
        std::fs::create_dir_all(data_dir)
            .map_err(|e| CoreError::InvalidDataDir(format!("{}: {e}", data_dir.display())))?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .thread_name("acp-core")
            .enable_all()
            .build()?;
        let core = Self {
            data_dir: data_dir.to_path_buf(),
            sink,
            runtime,
            ping_seq: AtomicU64::new(0),
        };
        core.announce_ready();
        Ok(core)
    }

    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }

    pub fn runtime(&self) -> &tokio::runtime::Runtime {
        &self.runtime
    }

    /// `{dataDir, coreVersion}`。
    pub fn describe(&self) -> Value {
        json!({
            "dataDir": self.data_dir.to_string_lossy(),
            "coreVersion": CORE_VERSION,
        })
    }

    /// 主动向 `acp/agent_state` 推一条 `core_ready`（R0 验收第 2 项）。
    /// 形状对齐 R1 的 agent_state payload：`agentId` 为 null 表示核心自身。
    pub fn announce_ready(&self) {
        let payload = json!({
            "agentId": null,
            "state": "core_ready",
            "dataDir": self.data_dir.to_string_lossy(),
            "coreVersion": CORE_VERSION,
            "droppedUpdates": 0,
        });
        self.emit(EventChannel::AgentState, payload);
    }

    /// 往返命令：回 `{pong, sequence, coreVersion}`。
    pub fn ping(&self, echo: &str) -> Result<Value> {
        let sequence = self.ping_seq.fetch_add(1, Ordering::Relaxed) + 1;
        Ok(json!({
            "pong": echo,
            "sequence": sequence,
            "coreVersion": CORE_VERSION,
        }))
    }

    pub(crate) fn emit(&self, channel: EventChannel, payload: Value) {
        self.sink.emit(channel, payload.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::RecordingSink;

    #[test]
    fn new_core_announces_ready_and_pings() {
        let sink = Arc::new(RecordingSink::default());
        let dir = std::env::temp_dir().join(format!("acp-core-test-{}", std::process::id()));
        let core = Core::new(&dir, sink.clone()).expect("core");
        let events = sink.take();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].0, EventChannel::AgentState);
        let v: Value = serde_json::from_str(&events[0].1).expect("json");
        assert_eq!(v["state"], "core_ready");
        assert!(v["agentId"].is_null());

        let p1 = core.ping("a").expect("ping");
        let p2 = core.ping("b").expect("ping");
        assert_eq!(p1["pong"], "a");
        assert_eq!(p1["sequence"], 1);
        assert_eq!(p2["sequence"], 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn relative_data_dir_is_rejected() {
        let sink = Arc::new(RecordingSink::default());
        let err = Core::new("relative/dir", sink).expect_err("must fail");
        assert_eq!(err.code(), "invalid_data_dir");
    }
}
