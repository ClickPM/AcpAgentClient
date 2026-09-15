//! 开发用 CLI（ROUNDS.md § 0 第 2 条）：绕过 frb 直接调 acp-core，事件按 JSON 行打到 stdout。
//! R0 只有 `ping`；R1 加 `--agent / --cwd / --prompt / --auto-permission / --cancel-after`。不发布。
//! 参数手工解析，不引 clap（CLAUDE.md 规则 1 通用库清单之外不加库）。

use std::io::Write;
use std::sync::Arc;

use acp_core::core::Core;
use acp_core::events::{EventChannel, EventSink};

struct StdoutSink;

impl EventSink for StdoutSink {
    fn emit(&self, channel: EventChannel, payload: String) {
        let line = serde_json::json!({ "event": channel.name(), "payload": payload });
        let mut out = std::io::stdout().lock();
        let _ = writeln!(out, "{line}");
    }
}

const USAGE: &str = "usage: acp-smoke ping [--data-dir <abs dir>] [--echo <text>]";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = run(&args);
    std::process::exit(code);
}

fn run(args: &[String]) -> i32 {
    let Some(cmd) = args.first() else {
        eprintln!("{USAGE}");
        return 2;
    };
    match cmd.as_str() {
        "ping" => ping(&args[1..]),
        "--version" | "-V" => {
            println!("acp-smoke {} (acp-core {})", env!("CARGO_PKG_VERSION"), acp_core::core::CORE_VERSION);
            0
        }
        _ => {
            eprintln!("{USAGE}");
            2
        }
    }
}

fn ping(args: &[String]) -> i32 {
    let mut data_dir: Option<String> = None;
    let mut echo = String::from("smoke");
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--data-dir" if i + 1 < args.len() => {
                data_dir = Some(args[i + 1].clone());
                i += 2;
            }
            "--echo" if i + 1 < args.len() => {
                echo = args[i + 1].clone();
                i += 2;
            }
            _ => {
                eprintln!("{USAGE}");
                return 2;
            }
        }
    }
    let data_dir = data_dir.unwrap_or_else(|| {
        std::env::temp_dir()
            .join("acp-smoke")
            .to_string_lossy()
            .into_owned()
    });
    let core = match Core::new(&data_dir, Arc::new(StdoutSink)) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("core init failed: {e}");
            return 1;
        }
    };
    match core.ping(&echo) {
        Ok(v) => {
            println!("{}", serde_json::json!({ "result": "ping", "payload": v }));
            0
        }
        Err(e) => {
            eprintln!("ping failed: {e}");
            1
        }
    }
}
