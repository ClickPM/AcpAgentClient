//! 开发用 CLI（ROUNDS.md § 0 第 2 条）：绕过 frb 直接调 acp-core，事件按 JSON 行打到 stdout。不发布。
//! 参数手工解析，不引 clap（CLAUDE.md 规则 1 通用库清单之外不加库）。
//!
//! ```text
//! acp-smoke ping [--data-dir <abs>] [--echo <text>]
//! acp-smoke run --agent <id> --cwd <dir> [--prompt "<text>"] [--data-dir <abs>]
//!               [--command <program> [--arg <a>]... [--env K=V]...]   # 先写进 data-dir 的 settings.json（custom 型）
//!               [--auto-permission allow_once|allow_always|reject_once|reject_always|cancel|none]   # 默认 allow_once；none = 留在队列里不回
//!               [--auto-elicitation accept|decline|cancel]                                       # 默认 accept
//!               [--cancel-after <ms>] [--auth-input <text>] [--auth-input-delay <ms>] [--auth-stdin] [--only-initialize] [--timeout <ms>]
//!               [--config <id>=<value>]...   # session/new 之后逐条 session/set_config_option；value 是 JSON，解不开就当 select 的 value id
//! ```
//!
//! `run` 的主线：core_init → agent_connect → session/new（`-32000` 时按 initialize 的第一个 authMethod 走认证：
//! terminal 型在 pty 里跑，`--auth-input` 看到含 "key" 的提示后写入（提示不可见时 `--auth-input-delay` 毫秒后兜底写入，默认 5000：
//! dsh 的 `--setup` 在 Windows TTY 上把提示吞掉了，见任务卡）、`--auth-stdin` 把本进程 stdin 逐行转进去；agent 型调 authenticate
//! 后重试）→ session/prompt（`--cancel-after` 到点发 cancel）→ agent_disconnect。
//! 事件行：`{"event": "<acp/...>", "payload": "<json string>"}`；结果行：`{"result": "<step>", ...}`。

use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use acp_core::core::Core;
use acp_core::events::{EventChannel, EventSink};
use serde_json::{Value, json};

/// stdout JSON 行 + 转发给 `run` 的反应线程。
struct StdoutSink {
    forward: Mutex<Option<mpsc::Sender<(EventChannel, String)>>>,
}

impl EventSink for StdoutSink {
    fn emit(&self, channel: EventChannel, payload: String) {
        let line = json!({ "event": channel.name(), "payload": payload });
        {
            let mut out = std::io::stdout().lock();
            let _ = writeln!(out, "{line}");
        }
        if let Ok(guard) = self.forward.lock()
            && let Some(tx) = guard.as_ref()
        {
            let _ = tx.send((channel, payload));
        }
    }
}

fn print_result(step: &str, payload: Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{}", json!({ "result": step, "payload": payload }));
}

/// `_meta` 字段名；键用 `acp_core::meta_keys` 的常量（validate.ps1 规则 2 检查）。
const META_FIELD: &str = "_meta";

const USAGE: &str = "usage:\n  acp-smoke ping [--data-dir <abs dir>] [--echo <text>]\n  acp-smoke run --agent <id> --cwd <dir> [--prompt <text>] [--data-dir <abs>] [--command <program> [--arg <a>]... [--env K=V]...]\n                [--auto-permission allow_once|allow_always|reject_once|reject_always|cancel|none] [--auto-elicitation accept|decline|cancel]\n                [--cancel-after <ms>] [--auth-input <text>] [--auth-stdin] [--only-initialize] [--timeout <ms>]";

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
        "run" => match RunArgs::parse(&args[1..]) {
            Ok(opts) => run_agent(opts),
            Err(e) => {
                eprintln!("{e}\n{USAGE}");
                2
            }
        },
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

fn default_data_dir() -> String {
    std::env::temp_dir().join("acp-smoke").to_string_lossy().into_owned()
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
    let data_dir = data_dir.unwrap_or_else(default_data_dir);
    let sink = Arc::new(StdoutSink { forward: Mutex::new(None) });
    let core = match Core::new(&data_dir, sink) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("core init failed: {e}");
            return 1;
        }
    };
    match core.ping(&echo) {
        Ok(v) => {
            print_result("ping", v);
            0
        }
        Err(e) => {
            eprintln!("ping failed: {e}");
            1
        }
    }
}

#[derive(Debug)]
struct RunArgs {
    agent: String,
    cwd: PathBuf,
    prompt: Option<String>,
    data_dir: String,
    command: Option<String>,
    command_args: Vec<String>,
    command_env: Vec<(String, String)>,
    auto_permission: String,
    auto_elicitation: String,
    cancel_after: Option<u64>,
    auth_input: Option<String>,
    auth_input_delay: Duration,
    auth_stdin: bool,
    only_initialize: bool,
    timeout: Duration,
    config: Vec<(String, Value)>,
}

impl RunArgs {
    fn parse(args: &[String]) -> Result<Self, String> {
        let mut out = RunArgs {
            agent: String::new(),
            cwd: PathBuf::new(),
            prompt: None,
            data_dir: default_data_dir(),
            command: None,
            command_args: Vec::new(),
            command_env: Vec::new(),
            auto_permission: "allow_once".into(),
            auto_elicitation: "accept".into(),
            cancel_after: None,
            auth_input: None,
            auth_input_delay: Duration::from_millis(5000),
            auth_stdin: false,
            only_initialize: false,
            timeout: Duration::from_secs(600),
            config: Vec::new(),
        };
        let mut i = 0;
        let value = |i: usize, name: &str| -> Result<String, String> {
            args.get(i + 1).cloned().ok_or_else(|| format!("{name} needs a value"))
        };
        while i < args.len() {
            let flag = args[i].as_str();
            match flag {
                "--agent" => out.agent = value(i, flag)?,
                "--cwd" => out.cwd = PathBuf::from(value(i, flag)?),
                "--prompt" => out.prompt = Some(value(i, flag)?),
                "--data-dir" => out.data_dir = value(i, flag)?,
                "--command" => out.command = Some(value(i, flag)?),
                "--arg" => out.command_args.push(value(i, flag)?),
                "--env" => {
                    let kv = value(i, flag)?;
                    let (k, v) = kv.split_once('=').ok_or_else(|| format!("--env expects K=V, got {kv}"))?;
                    out.command_env.push((k.to_string(), v.to_string()));
                }
                "--auto-permission" => out.auto_permission = value(i, flag)?,
                "--auto-elicitation" => out.auto_elicitation = value(i, flag)?,
                "--cancel-after" => out.cancel_after = Some(value(i, flag)?.parse().map_err(|e| format!("--cancel-after: {e}"))?),
                "--auth-input" => out.auth_input = Some(value(i, flag)?),
                "--auth-input-delay" => out.auth_input_delay = Duration::from_millis(value(i, flag)?.parse().map_err(|e| format!("--auth-input-delay: {e}"))?),
                "--timeout" => out.timeout = Duration::from_millis(value(i, flag)?.parse().map_err(|e| format!("--timeout: {e}"))?),
                "--config" => {
                    let kv = value(i, flag)?;
                    let (k, v) = kv.split_once('=').ok_or_else(|| format!("--config expects id=value, got {kv}"))?;
                    let parsed = serde_json::from_str::<Value>(v).unwrap_or_else(|_| Value::String(v.to_string()));
                    out.config.push((k.to_string(), parsed));
                }
                "--auth-stdin" => {
                    out.auth_stdin = true;
                    i += 1;
                    continue;
                }
                "--only-initialize" => {
                    out.only_initialize = true;
                    i += 1;
                    continue;
                }
                other => return Err(format!("unknown argument {other}")),
            }
            i += 2;
        }
        if out.agent.is_empty() {
            return Err("--agent is required".into());
        }
        if !out.cwd.is_absolute() {
            return Err("--cwd must be an absolute path".into());
        }
        if !["allow_once", "allow_always", "reject_once", "reject_always", "cancel", "none"].contains(&out.auto_permission.as_str()) {
            return Err(format!("--auto-permission: unknown value {}", out.auto_permission));
        }
        if !["accept", "decline", "cancel"].contains(&out.auto_elicitation.as_str()) {
            return Err(format!("--auto-elicitation: unknown value {}", out.auto_elicitation));
        }
        Ok(out)
    }
}

/// 反应线程的共享状态：认证终端 id、是否已经把 `--auth-input` 写进去。
#[derive(Default)]
struct Reactor {
    auth_terminal: Option<String>,
    auth_output: String,
    auth_input_sent: bool,
    client_requests: u64,
}

fn run_agent(opts: RunArgs) -> i32 {
    let (tx, rx) = mpsc::channel::<(EventChannel, String)>();
    let sink = Arc::new(StdoutSink { forward: Mutex::new(Some(tx)) });
    let core = match Core::new(&opts.data_dir, sink) {
        Ok(c) => Arc::new(c),
        Err(e) => {
            eprintln!("core init failed: {e}");
            return 1;
        }
    };
    if let Some(command) = &opts.command {
        let mut env = serde_json::Map::new();
        for (k, v) in &opts.command_env {
            env.insert(k.clone(), Value::String(v.clone()));
        }
        let server = json!({ "type": "custom", "command": command, "args": opts.command_args, "env": env });
        if let Err(e) = core.agent_settings_set(&opts.agent, server) {
            eprintln!("agent_settings_set failed: {e}");
            return 1;
        }
    }

    // 反应线程：自动回应 client_request、把 --auth-input 写进认证终端。
    let reactor = Arc::new(Mutex::new(Reactor::default()));
    {
        let core = core.clone();
        let reactor = reactor.clone();
        let auto_permission = opts.auto_permission.clone();
        let auto_elicitation = opts.auto_elicitation.clone();
        let auth_input = opts.auth_input.clone();
        let auth_input_delay = opts.auth_input_delay;
        let agent = opts.agent.clone();
        std::thread::spawn(move || {
            while let Ok((channel, payload)) = rx.recv() {
                let Ok(v) = serde_json::from_str::<Value>(&payload) else { continue };
                match channel {
                    EventChannel::ClientRequest => {
                        let Some(request_id) = v["requestId"].as_str() else { continue };
                        let method = v["method"].as_str().unwrap_or_default();
                        let response = match method {
                            "session/request_permission" if auto_permission == "none" => continue,
                            "session/request_permission" => permission_response(&v["params"], &auto_permission),
                            "elicitation/create" => elicitation_response(&v["params"], &auto_elicitation),
                            _ => continue,
                        };
                        if let Ok(mut r) = reactor.lock() {
                            r.client_requests += 1;
                        }
                        match core.acp_respond(&agent, request_id, response) {
                            Ok(v) => print_result("acp_respond", v),
                            Err(e) => eprintln!("acp_respond failed: {e}"),
                        }
                    }
                    EventChannel::AgentState => {
                        if v["state"] == "authenticating"
                            && let Some(id) = v["terminalId"].as_str()
                        {
                            if let Ok(mut r) = reactor.lock() {
                                r.auth_terminal = Some(id.to_string());
                            }
                            // 兜底：提示迟迟不出现（或根本不可见）也在 delay 后把输入写进去。
                            if let Some(input) = auth_input.clone() {
                                let core = core.clone();
                                let reactor = reactor.clone();
                                let id = id.to_string();
                                let delay = auth_input_delay;
                                std::thread::spawn(move || {
                                    std::thread::sleep(delay);
                                    let due = reactor.lock().map(|mut r| {
                                        if r.auth_input_sent {
                                            false
                                        } else {
                                            r.auth_input_sent = true;
                                            true
                                        }
                                    });
                                    if matches!(due, Ok(true)) {
                                        let data = format!("{input}\r");
                                        match core.runtime().block_on(core.terminal_write(&id, data.as_bytes())) {
                                            Ok(v) => print_result("terminal_write(auth-input-delay)", v),
                                            Err(e) => eprintln!("terminal_write failed: {e}"),
                                        }
                                    }
                                });
                            }
                        }
                    }
                    EventChannel::TerminalOutput => {
                        let Some(input) = auth_input.as_ref() else { continue };
                        let Some(bytes) = v["bytes"].as_str() else { continue };
                        let text = String::from_utf8_lossy(&base64_decode(bytes)).into_owned();
                        let write_to = {
                            let Ok(mut r) = reactor.lock() else { continue };
                            r.auth_output.push_str(&text);
                            let prompt_seen = r.auth_output.to_ascii_lowercase().contains("key");
                            if prompt_seen && !r.auth_input_sent {
                                r.auth_input_sent = true;
                                r.auth_terminal.clone().or_else(|| v["terminalId"].as_str().map(str::to_string))
                            } else {
                                None
                            }
                        };
                        if let Some(id) = write_to {
                            let data = format!("{input}\r");
                            if let Err(e) = core.runtime().block_on(core.terminal_write(&id, data.as_bytes())) {
                                eprintln!("terminal_write failed: {e}");
                            }
                        }
                    }
                    _ => {}
                }
            }
        });
    }

    let code = core.runtime().block_on(async {
        match tokio::time::timeout(opts.timeout, drive(&core, &opts, &reactor)).await {
            Ok(code) => code,
            Err(_) => {
                eprintln!("timed out after {:?}", opts.timeout);
                1
            }
        }
    });
    let status = core.agents_status();
    print_result("agents_status", status);
    let _ = core.runtime().block_on(core.agent_disconnect(&opts.agent));
    code
}

async fn drive(core: &Arc<Core>, opts: &RunArgs, reactor: &Arc<Mutex<Reactor>>) -> i32 {
    let connect = match core.agent_connect(&opts.agent, Some(opts.cwd.clone())).await {
        Ok(v) => v,
        Err(e) => {
            eprintln!("agent_connect failed: {e}");
            return 1;
        }
    };
    print_result("agent_connect", connect.clone());
    if opts.only_initialize {
        return 0;
    }

    let session = match core.session_new(&opts.agent, opts.cwd.clone()).await {
        Ok(v) => v,
        Err(acp_core::error::CoreError::AuthRequired { message, .. }) => {
            eprintln!("auth required: {message}");
            let methods = connect["initialize"]["authMethods"].as_array().cloned().unwrap_or_default();
            let Some(method) = methods.first() else {
                eprintln!("agent offers no auth methods");
                return 1;
            };
            let method_id = method["id"].as_str().unwrap_or_default().to_string();
            let legacy_terminal = method
                .get(META_FIELD)
                .is_some_and(|m| m.get(acp_core::meta_keys::outbound::TERMINAL_AUTH).is_some());
            if method["type"] == "terminal" || legacy_terminal {
                if opts.auth_stdin {
                    spawn_stdin_relay(core.clone(), reactor.clone());
                }
                match core.terminal_auth_run(&opts.agent, &method_id, opts.cwd.clone()).await {
                    Ok(v) => {
                        print_result("terminal_auth_run", v.clone());
                        v["session"].clone()
                    }
                    Err(e) => {
                        eprintln!("terminal_auth_run failed: {e}");
                        return 1;
                    }
                }
            } else {
                match core.authenticate(&opts.agent, &method_id).await {
                    Ok(v) => print_result("authenticate", v),
                    Err(e) => {
                        eprintln!("authenticate failed: {e}");
                        return 1;
                    }
                }
                match core.session_new(&opts.agent, opts.cwd.clone()).await {
                    Ok(v) => v,
                    Err(e) => {
                        eprintln!("session_new after authenticate failed: {e}");
                        return 1;
                    }
                }
            }
        }
        Err(e) => {
            eprintln!("session_new failed: {e}");
            return 1;
        }
    };
    print_result("session_new", session.clone());
    let Some(session_id) = session["sessionId"].as_str().map(str::to_string) else {
        eprintln!("session_new returned no sessionId");
        return 1;
    };

    for (config_id, value) in &opts.config {
        match core.session_set_config_option(&opts.agent, &session_id, config_id, value.clone()).await {
            Ok(v) => print_result("session_set_config_option", v),
            Err(e) => {
                eprintln!("session_set_config_option {config_id} failed: {e}");
                return 1;
            }
        }
    }

    let Some(prompt) = &opts.prompt else {
        return 0;
    };
    if let Some(ms) = opts.cancel_after {
        let core = core.clone();
        let agent = opts.agent.clone();
        let session_id = session_id.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(ms)).await;
            match core.session_cancel(&agent, &session_id) {
                Ok(v) => print_result("session_cancel", v),
                Err(e) => eprintln!("session_cancel failed: {e}"),
            }
        });
    }
    let blocks = json!([{ "type": "text", "text": prompt }]);
    match core.session_prompt(&opts.agent, &session_id, blocks).await {
        Ok(v) => {
            print_result("session_prompt", v);
            0
        }
        Err(e) => {
            eprintln!("session_prompt failed: {e}");
            1
        }
    }
}

/// `--auth-stdin`：把本进程 stdin 的每一行（含回车）写进认证终端。等 `authenticating` 事件给出 terminalId。
fn spawn_stdin_relay(core: Arc<Core>, reactor: Arc<Mutex<Reactor>>) {
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines() {
            let Ok(line) = line else { break };
            let id = loop {
                if let Ok(r) = reactor.lock()
                    && let Some(id) = r.auth_terminal.clone()
                {
                    break id;
                }
                std::thread::sleep(Duration::from_millis(50));
            };
            let data = format!("{line}\r");
            if let Err(e) = core.runtime().block_on(core.terminal_write(&id, data.as_bytes())) {
                eprintln!("terminal_write failed: {e}");
            }
        }
    });
}

fn permission_response(params: &Value, choice: &str) -> Value {
    if choice == "cancel" {
        return json!({ "outcome": { "outcome": "cancelled" } });
    }
    let options = params["options"].as_array().cloned().unwrap_or_default();
    let picked = options
        .iter()
        .find(|o| o["kind"] == choice)
        .or_else(|| options.first())
        .and_then(|o| o["optionId"].as_str())
        .unwrap_or_default();
    json!({ "outcome": { "outcome": "selected", "optionId": picked } })
}

fn elicitation_response(params: &Value, choice: &str) -> Value {
    match choice {
        "decline" => json!({ "action": "decline" }),
        "cancel" => json!({ "action": "cancel" }),
        _ => {
            if params["mode"] == "url" {
                return json!({ "action": "accept" });
            }
            let mut content = serde_json::Map::new();
            if let Some(props) = params["requestedSchema"]["properties"].as_object() {
                for (name, schema) in props {
                    content.insert(name.clone(), sample_value(schema));
                }
            }
            json!({ "action": "accept", "content": content })
        }
    }
}

/// 给 elicitation 表单填一个合规的样例值：default → oneOf / enum 的第一项 → 按类型给默认。
fn sample_value(schema: &Value) -> Value {
    if let Some(d) = schema.get("default") {
        return d.clone();
    }
    if let Some(first) = schema["oneOf"].as_array().and_then(|a| a.first()) {
        return first["const"].clone();
    }
    if let Some(first) = schema["enum"].as_array().and_then(|a| a.first()) {
        return first.clone();
    }
    match schema["type"].as_str().unwrap_or_default() {
        "boolean" => json!(false),
        "number" | "integer" => schema.get("minimum").cloned().unwrap_or(json!(0)),
        "array" => {
            let min = schema["minItems"].as_u64().unwrap_or(0);
            if min == 0 {
                return json!([]);
            }
            let first = schema["items"]["anyOf"]
                .as_array()
                .and_then(|a| a.first())
                .map(|o| o["const"].clone())
                .unwrap_or(json!("smoke"));
            json!([first])
        }
        _ => json!("smoke"),
    }
}

/// 标准 base64 解码（忽略非法字符），只给 `--auth-input` 看终端输出用。
fn base64_decode(text: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let mut acc: u32 = 0;
    let mut bits = 0;
    for c in text.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => continue,
        };
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((acc >> bits) & 0xff) as u8);
        }
    }
    out
}
