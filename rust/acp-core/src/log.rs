//! `logs/acp-<日期>.log`（docs/design.md § 10，画板 70 的「日志路径」）：脱敏后的 ACP 流量行与连接状态，与 `acp/traffic` /
//! `acp/agent_state` 同源——事件在进 sink 之前已经过 `redact`（规则 8），这里只是多写一份到磁盘。
//! 写盘在一条独立的 std 线程上（事件是从 tokio 线程发出的，不能在那里做阻塞 IO）；日期按 UTC（不引 chrono，
//! 也不做时区换算——文件名只用来分天）。

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::mpsc;

use serde_json::Value;

use crate::events::{EventChannel, EventSink};

/// 把事件转发给真正的出口，同时按通道写日志。
pub struct LoggingSink {
    inner: std::sync::Arc<dyn EventSink>,
    writer: LogWriter,
}

impl LoggingSink {
    pub fn new(inner: std::sync::Arc<dyn EventSink>, logs_dir: PathBuf) -> Self {
        Self { inner, writer: LogWriter::new(logs_dir) }
    }

    pub fn log_path(&self) -> &Path {
        &self.writer.path
    }
}

impl EventSink for LoggingSink {
    fn emit(&self, channel: EventChannel, payload: String) {
        match channel {
            EventChannel::Traffic => {
                if let Ok(v) = serde_json::from_str::<Value>(&payload) {
                    let dir = v.get("direction").and_then(Value::as_str).unwrap_or("?");
                    let agent = v.get("agentId").and_then(Value::as_str).unwrap_or("-");
                    let line = v.get("line").and_then(Value::as_str).unwrap_or("");
                    self.writer.line(&format!("{dir:<6} {agent} {line}"));
                }
            }
            EventChannel::AgentState => {
                if let Ok(v) = serde_json::from_str::<Value>(&payload) {
                    let agent = v.get("agentId").and_then(Value::as_str).unwrap_or("core");
                    let state = v.get("state").and_then(Value::as_str).unwrap_or("?");
                    let code = v.get("code").map(|c| format!(" code={c}")).unwrap_or_default();
                    self.writer.line(&format!("state  {agent} {state}{code}"));
                }
            }
            EventChannel::RegistryProgress => {
                if let Ok(v) = serde_json::from_str::<Value>(&payload) {
                    let agent = v.get("agentId").and_then(Value::as_str).unwrap_or("node");
                    let step = v.get("step").and_then(Value::as_str).unwrap_or("?");
                    let error = v.get("error").and_then(Value::as_str).map(|e| format!(" error={e}")).unwrap_or_default();
                    self.writer.line(&format!("install {agent} {step}{error}"));
                }
            }
            EventChannel::SessionUpdate | EventChannel::ClientRequest | EventChannel::TerminalOutput => {}
        }
        self.inner.emit(channel, payload);
    }
}

/// 追加写的日志文件；线程退出时（`Core` 析构）把剩余行写完。
pub struct LogWriter {
    pub path: PathBuf,
    tx: std::sync::Mutex<Option<mpsc::Sender<String>>>,
}

impl LogWriter {
    pub fn new(logs_dir: PathBuf) -> Self {
        let path = logs_dir.join(format!("acp-{}.log", utc_date(std::time::SystemTime::now())));
        let (tx, rx) = mpsc::channel::<String>();
        let file_path = path.clone();
        let spawned = std::thread::Builder::new().name("acp-log".into()).spawn(move || {
            let _ = std::fs::create_dir_all(file_path.parent().unwrap_or(Path::new(".")));
            let mut file = std::fs::OpenOptions::new().create(true).append(true).open(&file_path).ok();
            while let Ok(line) = rx.recv() {
                if let Some(f) = file.as_mut() {
                    let _ = writeln!(f, "{line}");
                    let _ = f.flush();
                }
            }
        });
        Self { path, tx: std::sync::Mutex::new(spawned.is_ok().then_some(tx)) }
    }

    pub fn line(&self, text: &str) {
        let ts = crate::core::now_ms();
        if let Ok(guard) = self.tx.lock()
            && let Some(tx) = guard.as_ref()
        {
            let _ = tx.send(format!("{ts} {text}"));
        }
    }
}

/// `SystemTime` → `YYYY-MM-DD`（UTC；Howard Hinnant 的 civil_from_days）。
pub fn utc_date(t: std::time::SystemTime) -> String {
    let secs = t.duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let days = secs.div_euclid(86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, UNIX_EPOCH};

    #[test]
    fn utc_date_matches_known_days() {
        assert_eq!(utc_date(UNIX_EPOCH), "1970-01-01");
        // 2026-09-16 00:00:00 UTC = 1789516800
        assert_eq!(utc_date(UNIX_EPOCH + Duration::from_secs(1_789_516_800)), "2026-09-16");
        // 闰日：2024-02-29 = 1709164800
        assert_eq!(utc_date(UNIX_EPOCH + Duration::from_secs(1_709_164_800)), "2024-02-29");
    }

    #[test]
    fn writer_appends_lines_to_the_day_file() {
        let dir = std::env::temp_dir().join(format!("acp-core-log-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let writer = LogWriter::new(dir.clone());
        writer.line("in     a {\"x\":1}");
        writer.line("state  a exited");
        // 关掉发送端让线程收尾，再读文件。
        drop(writer.tx.lock().expect("lock").take());
        std::thread::sleep(Duration::from_millis(200));
        let text = std::fs::read_to_string(&writer.path).expect("log file");
        assert!(text.contains("in     a {\"x\":1}"), "{text}");
        assert!(text.contains("state  a exited"));
        assert!(writer.path.file_name().expect("name").to_string_lossy().starts_with("acp-"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
