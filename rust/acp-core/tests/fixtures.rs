//! 契约锚（ROUNDS.md § 0 第 3 条）：`test/fixtures/*.jsonl` 的每一条线上行都要能用 rust-sdk 类型反序列化，
//! 落在我们编译出的 15 变体面内；标 `expect: reject` 的行（`notice`、假想的未来变体）必须失败。
//! 文件格式见 test/fixtures/README.md。

use std::collections::HashMap;
use std::path::PathBuf;

use agent_client_protocol::schema::v1 as acp;
use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Deserialize)]
struct Line {
    dir: String,
    #[serde(default)]
    tag: Option<String>,
    #[serde(default)]
    expect: Option<String>,
    #[serde(default)]
    msg: Option<Value>,
}

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("test")
        .join("fixtures")
}

fn cast<T: for<'de> Deserialize<'de>>(v: &Value) -> Result<(), String> {
    serde_json::from_value::<T>(v.clone())
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// 按方法名把 params 喂给对应的 rust-sdk 请求 / 通知类型。未列出的方法直接算失败，逼着新 fixtures 补表。
fn parse_request(method: &str, params: &Value) -> Result<(), String> {
    match method {
        "initialize" => cast::<acp::InitializeRequest>(params),
        "session/new" => cast::<acp::NewSessionRequest>(params),
        "session/prompt" => cast::<acp::PromptRequest>(params),
        "session/cancel" => cast::<acp::CancelNotification>(params),
        "session/update" => cast::<acp::SessionNotification>(params),
        "session/request_permission" => cast::<acp::RequestPermissionRequest>(params),
        "authenticate" => cast::<acp::AuthenticateRequest>(params),
        "elicitation/create" => cast::<acp::CreateElicitationRequest>(params),
        // 两条不需要回应的通知（R3 补表，R2 的 BACKLOG 条目）：URL elicitation 收尾与 agent 撤回自己的请求。
        "elicitation/complete" => cast::<acp::CompleteElicitationNotification>(params),
        "$/cancel_request" => cast::<acp::CancelRequestNotification>(params),
        "fs/read_text_file" => cast::<acp::ReadTextFileRequest>(params),
        "fs/write_text_file" => cast::<acp::WriteTextFileRequest>(params),
        "terminal/create" => cast::<acp::CreateTerminalRequest>(params),
        "terminal/output" => cast::<acp::TerminalOutputRequest>(params),
        "terminal/wait_for_exit" => cast::<acp::WaitForTerminalExitRequest>(params),
        "terminal/kill" => cast::<acp::KillTerminalRequest>(params),
        "terminal/release" => cast::<acp::ReleaseTerminalRequest>(params),
        other => Err(format!("fixture uses unmapped method {other}")),
    }
}

fn parse_response(method: &str, result: &Value) -> Result<(), String> {
    match method {
        "initialize" => cast::<acp::InitializeResponse>(result),
        "session/new" => cast::<acp::NewSessionResponse>(result),
        "session/prompt" => cast::<acp::PromptResponse>(result),
        "session/request_permission" => cast::<acp::RequestPermissionResponse>(result),
        "authenticate" => cast::<acp::AuthenticateResponse>(result),
        "elicitation/create" => cast::<acp::CreateElicitationResponse>(result),
        "fs/read_text_file" => cast::<acp::ReadTextFileResponse>(result),
        "fs/write_text_file" => cast::<acp::WriteTextFileResponse>(result),
        "terminal/create" => cast::<acp::CreateTerminalResponse>(result),
        "terminal/output" => cast::<acp::TerminalOutputResponse>(result),
        "terminal/wait_for_exit" => cast::<acp::WaitForTerminalExitResponse>(result),
        "terminal/kill" => cast::<acp::KillTerminalResponse>(result),
        "terminal/release" => cast::<acp::ReleaseTerminalResponse>(result),
        other => Err(format!("fixture uses unmapped response method {other}")),
    }
}

#[derive(Default, Debug)]
struct Tally {
    ok: usize,
    rejected_as_expected: Vec<String>,
    unexpected: Vec<String>,
    update_variants: HashMap<String, usize>,
    /// 请求 id → 方法名，用来给响应行找类型。fixtures 是一条连续的线上流按场景切文件，所以跨文件共享。
    pending: HashMap<String, String>,
}

fn run_file(path: &PathBuf, tally: &mut Tally) {
    let text = std::fs::read_to_string(path).expect("read fixture");
    let file = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    for (n, raw) in text.lines().enumerate() {
        if raw.trim().is_empty() {
            continue;
        }
        let line: Line = serde_json::from_str(raw)
            .unwrap_or_else(|e| panic!("{file}:{} not a fixture line: {e}", n + 1));
        let Some(msg) = line.msg.as_ref() else {
            // local / stderr 行不是协议消息。
            assert!(matches!(line.dir.as_str(), "local" | "stderr"), "{file}:{} has no msg", n + 1);
            continue;
        };
        let where_ = format!("{file}:{} [{}]", n + 1, line.tag.clone().unwrap_or_default());
        let outcome: Result<(), String> = if let Some(method) = msg.get("method").and_then(Value::as_str) {
            let params = msg.get("params").cloned().unwrap_or(Value::Null);
            if let Some(id) = msg.get("id") {
                tally.pending.insert(id.to_string(), method.to_string());
            }
            let r = parse_request(method, &params);
            if r.is_ok() && method == "session/update" {
                // 变体面：把 update 再序列化一次，读回 sessionUpdate 判别式，与 tag 对得上。
                let parsed: acp::SessionNotification = serde_json::from_value(params.clone()).expect("just parsed");
                let back = serde_json::to_value(&parsed.update).expect("serialize");
                let variant = back["sessionUpdate"].as_str().unwrap_or("?").to_string();
                assert_eq!(Some(&variant), line.tag.as_ref(), "{where_}: variant tag mismatch");
                *tally.update_variants.entry(variant).or_default() += 1;
            }
            r
        } else if let Some(result) = msg.get("result") {
            let id = msg.get("id").map(|v| v.to_string()).unwrap_or_default();
            let method = tally.pending.remove(&id).unwrap_or_else(|| panic!("{where_}: response to unknown id {id}"));
            parse_response(&method, result)
        } else if msg.get("error").is_some() {
            Ok(())
        } else {
            Err("neither request, notification nor response".into())
        };
        let expect_reject = line.expect.as_deref() == Some("reject");
        match (outcome, expect_reject) {
            (Ok(()), false) => tally.ok += 1,
            (Err(e), true) => tally.rejected_as_expected.push(format!("{where_}: {e}")),
            (Ok(()), true) => tally.unexpected.push(format!("{where_}: expected reject but parsed")),
            (Err(e), false) => tally.unexpected.push(format!("{where_}: {e}")),
        }
    }
}

#[test]
fn fixtures_round_trip_through_rust_sdk_types() {
    let dir = fixtures_dir();
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("fixtures dir {}: {e}", dir.display()))
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no fixtures in {}", dir.display());

    let mut tally = Tally::default();
    for f in &files {
        run_file(f, &mut tally);
    }
    assert!(tally.unexpected.is_empty(), "unexpected outcomes:\n{}", tally.unexpected.join("\n"));
    assert!(tally.ok > 0);
    // 两条故意的行：notice（sdk 的 unstable 伞不转发 unstable_session_notices）与假想的未来变体。
    assert_eq!(
        tally.rejected_as_expected.len(),
        2,
        "expected exactly two rejected lines, got {:?}",
        tally.rejected_as_expected
    );
    assert!(tally.rejected_as_expected.iter().any(|s| s.contains("[notice]")));
    assert!(tally.rejected_as_expected.iter().any(|s| s.contains("[artifact_update]")));

    // 15 个变体（docs/acp-projection.md § 2）在 fixtures 里全部出现过。
    let expected = [
        "user_message_chunk", "agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update",
        "plan", "available_commands_update", "current_mode_update", "config_option_update", "session_info_update",
        "usage_update", "plan_update", "plan_removed", "compaction_update", "compaction_summary_chunk",
    ];
    let missing: Vec<&str> = expected.iter().copied().filter(|v| !tally.update_variants.contains_key(*v)).collect();
    assert!(missing.is_empty(), "fixtures never exercise variants: {missing:?}");
    assert_eq!(tally.update_variants.len(), expected.len(), "unexpected extra variants: {:?}", tally.update_variants);
}
