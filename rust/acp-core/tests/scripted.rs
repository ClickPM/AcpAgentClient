//! 不拉进程的主线测试：用 rust-sdk 的 `Channel::duplex()` 把一个脚本化的假 agent（Agent 角色）接到
//! `AgentConnection::connect_with_transport`，验证 R1 的协议语义：
//! initialize → `session/new` 回 `-32000` → auth_required 事件 → 重试成功 → 一轮 prompt 含 `session/update`、
//! 未知变体（`notice`）被计数 + 告警、`session/request_permission` 进队列并由 `respond` 收尾、`end_turn` 带 usage；
//! cancel 后挂起与后到的权限请求都自动回 `cancelled`；elicitation form / url 与 `elicitation/complete` 转发；
//! 断开后 `exited` 事件。

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use acp_core::agent::AgentConnection;
use acp_core::command::LaunchSpec;
use acp_core::error::CoreError;
use acp_core::events::{EventChannel, EventSink};
use agent_client_protocol::schema::v1 as acp;
use agent_client_protocol::{Agent, Channel, Client, ConnectionTo, Responder, UntypedMessage};
use base64::prelude::*;
use serde_json::{Value, json};

/// 事件收集器：按到达顺序存 `(channel, payload)`，支持等待某条件。
#[derive(Default)]
struct Events {
    items: Mutex<Vec<(EventChannel, Value)>>,
}

impl EventSink for Events {
    fn emit(&self, channel: EventChannel, payload: String) {
        let v: Value = serde_json::from_str(&payload).expect("event payload is JSON");
        self.items.lock().expect("lock").push((channel, v));
    }
}

impl Events {
    fn snapshot(&self) -> Vec<(EventChannel, Value)> {
        self.items.lock().expect("lock").clone()
    }

    fn states(&self) -> Vec<String> {
        self.snapshot()
            .into_iter()
            .filter(|(c, _)| *c == EventChannel::AgentState)
            .filter_map(|(_, v)| v["state"].as_str().map(str::to_string))
            .collect()
    }

    fn updates(&self) -> Vec<String> {
        self.snapshot()
            .into_iter()
            .filter(|(c, _)| *c == EventChannel::SessionUpdate)
            .filter_map(|(_, v)| v["update"]["sessionUpdate"].as_str().map(str::to_string))
            .collect()
    }

    fn client_requests(&self) -> Vec<Value> {
        self.snapshot()
            .into_iter()
            .filter(|(c, _)| *c == EventChannel::ClientRequest)
            .map(|(_, v)| v)
            .collect()
    }

    async fn wait_for(&self, what: &str, pred: impl Fn(&[(EventChannel, Value)]) -> bool) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        loop {
            if pred(&self.snapshot()) {
                return;
            }
            assert!(tokio::time::Instant::now() < deadline, "timed out waiting for {what}; events: {:#?}", self.snapshot());
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}

#[derive(Default)]
struct FakeState {
    session_new_calls: AtomicU32,
    /// 收到 `session/cancel` 的次数。
    cancels: AtomicU32,
    /// 权限请求得到的回应（outcome 判别值）。
    permission_outcomes: Mutex<Vec<String>>,
    /// elicitation 得到的回应（action）。
    elicitation_actions: Mutex<Vec<String>>,
    /// 当前回合的 prompt responder（cancel 时用）。
    cancel_flag: Mutex<Option<tokio::sync::watch::Sender<bool>>>,
    /// `session/new` 给的 cwd（fs / terminal 场景要在它里面读写）。
    session_cwd: Mutex<Option<std::path::PathBuf>>,
    /// fs / terminal 场景里每个回调的结果（`{step, ok: <response json>}` 或 `{step, error: {code, message}}`）。
    callback_log: Mutex<Vec<Value>>,
    /// R6：收到的会话生命周期请求，按到达顺序记 `{method, sessionId?, cwd?, cursor?}`。
    lifecycle: Mutex<Vec<Value>>,
}

/// agent 侧发一个 client 请求并把结果记进日志（响应 serde 成 JSON，错误记 code / message）。
async fn call<Req>(cx: &ConnectionTo<Client>, state: &FakeState, step: &str, req: Req) -> Value
where
    Req: agent_client_protocol::JsonRpcRequest + Send + 'static,
    Req::Response: serde::Serialize,
{
    let outcome = match cx.send_request(req).block_task().await {
        Ok(resp) => json!({ "step": step, "ok": serde_json::to_value(&resp).expect("json") }),
        Err(e) => {
            let v = serde_json::to_value(&e).expect("json");
            json!({ "step": step, "error": { "code": v["code"], "message": e.message, "data": e.data } })
        }
    };
    state.callback_log.lock().expect("lock").push(outcome.clone());
    outcome
}

/// fs/* 与 terminal/* 七个回调的场景（R4）：写 → 读（1-based 行）→ 读不存在的 → 读 cwd 之外的 →
/// 前台命令（create / wait / output / kill 空操作 / release / release 后 output 报错）→ 后台命令（create / kill / wait / output / release）。
async fn run_fs_terminal_scenario(cx: &ConnectionTo<Client>, state: &FakeState, session_id: &str) {
    let cwd = state.session_cwd.lock().expect("lock").clone().expect("session cwd recorded");
    let file = cwd.join("r4 目录").join("r4.txt");
    let file_str = file.to_string_lossy().into_owned();
    let write: acp::WriteTextFileRequest =
        serde_json::from_value(json!({ "sessionId": session_id, "path": file_str, "content": "第一行\n第二行\n" })).expect("req");
    call(cx, state, "write", write).await;
    let read: acp::ReadTextFileRequest =
        serde_json::from_value(json!({ "sessionId": session_id, "path": file_str, "line": 2, "limit": 1 })).expect("req");
    call(cx, state, "read_line2", read).await;
    let missing: acp::ReadTextFileRequest =
        serde_json::from_value(json!({ "sessionId": session_id, "path": cwd.join("nope.txt").to_string_lossy() })).expect("req");
    call(cx, state, "read_missing", missing).await;
    let outside_path = std::env::temp_dir().join("acp-core-r4-outside.txt");
    let outside: acp::ReadTextFileRequest =
        serde_json::from_value(json!({ "sessionId": session_id, "path": outside_path.to_string_lossy() })).expect("req");
    call(cx, state, "read_outside", outside).await;
    let beyond: acp::ReadTextFileRequest =
        serde_json::from_value(json!({ "sessionId": session_id, "path": file_str, "line": 9 })).expect("req");
    call(cx, state, "read_beyond", beyond).await;

    // 前台命令：echo 在 PowerShell / cmd / sh 里都有。
    let create: acp::CreateTerminalRequest = serde_json::from_value(json!({
        "sessionId": session_id, "command": "echo", "args": ["r4-terminal-ok"], "outputByteLimit": 4096,
        "env": [{ "name": "ACP_R4", "value": "1" }]
    }))
    .expect("req");
    let created = call(cx, state, "create", create).await;
    let tid = created["ok"]["terminalId"].as_str().unwrap_or_default().to_string();
    let wait: acp::WaitForTerminalExitRequest = serde_json::from_value(json!({ "sessionId": session_id, "terminalId": tid })).expect("req");
    call(cx, state, "wait", wait).await;
    let output: acp::TerminalOutputRequest = serde_json::from_value(json!({ "sessionId": session_id, "terminalId": tid })).expect("req");
    call(cx, state, "output", output).await;
    let kill: acp::KillTerminalRequest = serde_json::from_value(json!({ "sessionId": session_id, "terminalId": tid })).expect("req");
    call(cx, state, "kill_after_exit", kill).await;
    let release: acp::ReleaseTerminalRequest = serde_json::from_value(json!({ "sessionId": session_id, "terminalId": tid })).expect("req");
    call(cx, state, "release", release).await;
    let after: acp::TerminalOutputRequest = serde_json::from_value(json!({ "sessionId": session_id, "terminalId": tid })).expect("req");
    call(cx, state, "output_after_release", after).await;

    // 后台命令：起一个长命令，看到输出后 kill，wait 拿到非零退出，output 仍在，release 收尾。
    let (command, args): (&str, Vec<&str>) = if cfg!(windows) {
        ("cmd", vec!["/c", "echo started && ping -n 30 127.0.0.1 > nul"])
    } else {
        ("sh", vec!["-c", "echo started; sleep 30"])
    };
    let create_bg: acp::CreateTerminalRequest =
        serde_json::from_value(json!({ "sessionId": session_id, "command": command, "args": args, "cwd": cwd.to_string_lossy() })).expect("req");
    let created = call(cx, state, "bg_create", create_bg).await;
    let bg = created["ok"]["terminalId"].as_str().unwrap_or_default().to_string();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    loop {
        let out: acp::TerminalOutputRequest = serde_json::from_value(json!({ "sessionId": session_id, "terminalId": bg })).expect("req");
        let v = call(cx, state, "bg_poll", out).await;
        if v["ok"]["output"].as_str().is_some_and(|s| s.contains("started")) {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "background command never printed: {v}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let kill: acp::KillTerminalRequest = serde_json::from_value(json!({ "sessionId": session_id, "terminalId": bg })).expect("req");
    call(cx, state, "bg_kill", kill).await;
    let wait: acp::WaitForTerminalExitRequest = serde_json::from_value(json!({ "sessionId": session_id, "terminalId": bg })).expect("req");
    call(cx, state, "bg_wait", wait).await;
    let out: acp::TerminalOutputRequest = serde_json::from_value(json!({ "sessionId": session_id, "terminalId": bg })).expect("req");
    call(cx, state, "bg_output", out).await;
    let release: acp::ReleaseTerminalRequest = serde_json::from_value(json!({ "sessionId": session_id, "terminalId": bg })).expect("req");
    call(cx, state, "bg_release", release).await;
}

fn session_update(session_id: &str, update: Value) -> UntypedMessage {
    UntypedMessage::new("session/update", json!({ "sessionId": session_id, "update": update })).expect("untyped")
}

fn permission_request(session_id: &str, tool_call_id: &str) -> acp::RequestPermissionRequest {
    serde_json::from_value(json!({
        "sessionId": session_id,
        "toolCall": { "toolCallId": tool_call_id },
        "options": [
            { "optionId": "allow-once", "name": "Allow once", "kind": "allow_once" },
            { "optionId": "reject-once", "name": "Reject", "kind": "reject_once" }
        ]
    }))
    .expect("permission request")
}

/// 脚本化假 agent。`scenario` 决定 prompt 回合里发什么。
fn spawn_fake_agent(state: Arc<FakeState>, transport: Channel, scenario: &'static str) -> tokio::task::JoinHandle<()> {
    let init_state = state.clone();
    let new_state = state.clone();
    let prompt_state = state.clone();
    let cancel_state = state.clone();
    let list_state = state.clone();
    let load_state = state.clone();
    let resume_state = state.clone();
    let close_state = state.clone();
    let delete_state = state.clone();
    tokio::spawn(async move {
        let result = Agent
            .builder()
            .name("fake-agent")
            .on_receive_request(
                async move |_req: acp::InitializeRequest, responder: Responder<acp::InitializeResponse>, _cx: ConnectionTo<Client>| {
                    let _ = &init_state;
                    let response: acp::InitializeResponse = serde_json::from_value(json!({
                        "protocolVersion": 1,
                        "agentInfo": { "name": "fake-agent", "version": "0.0.1" },
                        // R6：会话生命周期五件事都声明（能力门在前端，核心只转发）。
                        "agentCapabilities": {
                            "loadSession": true,
                            "sessionCapabilities": { "list": {}, "delete": {}, "resume": {}, "close": {} }
                        },
                        "authMethods": [
                            { "type": "terminal", "id": "fake-setup", "name": "Configure key", "args": ["--setup"] }
                        ]
                    }))
                    .expect("init response");
                    responder.respond(response)
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |req: acp::NewSessionRequest, responder: Responder<acp::NewSessionResponse>, _cx: ConnectionTo<Client>| {
                    *new_state.session_cwd.lock().expect("lock") = Some(req.cwd.clone());
                    let n = new_state.session_new_calls.fetch_add(1, Ordering::SeqCst);
                    if n == 0 {
                        responder.respond_with_error(acp::Error::new(-32000, "FAKE_KEY is not configured"))
                    } else {
                        responder.respond(acp::NewSessionResponse::new(acp::SessionId::new("sess_fake")))
                    }
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |req: acp::PromptRequest, responder: Responder<acp::PromptResponse>, cx: ConnectionTo<Client>| {
                    let state = prompt_state.clone();
                    let session_id = req.session_id.0.to_string();
                    let (cancel_tx, mut cancel_rx) = tokio::sync::watch::channel(false);
                    *state.cancel_flag.lock().expect("lock") = Some(cancel_tx);
                    // 不能在 handler 里等自己发出的请求（SDK 的 dispatch 循环会死锁），整轮放到独立任务里跑。
                    tokio::spawn(async move {
                        if scenario == "fs_terminal" {
                            run_fs_terminal_scenario(&cx, &state, &session_id).await;
                            responder.respond(acp::PromptResponse::new(acp::StopReason::EndTurn)).expect("respond");
                            return;
                        }
                        cx.send_notification(session_update(&session_id, json!({
                            "sessionUpdate": "agent_message_chunk",
                            "content": { "type": "text", "text": "hello" }
                        })))
                        .expect("send");
                        // 未知变体：我们的 feature 集编译不出 notice，核心必须计数 + 告警而不是崩。
                        cx.send_notification(session_update(&session_id, json!({
                            "sessionUpdate": "notice", "severity": "warning", "title": "degraded"
                        })))
                        .expect("send");
                        cx.send_notification(session_update(&session_id, json!({
                            "sessionUpdate": "tool_call", "toolCallId": "call_1", "title": "edit", "kind": "edit", "status": "pending"
                        })))
                        .expect("send");
                        if scenario == "withdraw" {
                            // 发了权限请求又撤回（$/cancel_request）：核心必须回 -32800，这里的 block_task 才能返回。
                            // 放在公共的第一条权限请求之前：这个场景里前端不回应任何请求。
                            let sent = cx.send_request(permission_request(&session_id, "call_withdrawn"));
                            sent.cancel().expect("send $/cancel_request");
                            let outcome = match sent.block_task().await {
                                Ok(_) => "unexpected_ok".to_string(),
                                Err(e) if e.code == acp::ErrorCode::RequestCancelled => "request_cancelled".to_string(),
                                Err(e) => format!("other_error:{}", e.message),
                            };
                            state.permission_outcomes.lock().expect("lock").push(outcome);
                            responder.respond(acp::PromptResponse::new(acp::StopReason::EndTurn)).expect("respond");
                            return;
                        }

                        let permission = cx.send_request(permission_request(&session_id, "call_1")).block_task().await.expect("permission");
                        let outcome = serde_json::to_value(&permission).expect("json")["outcome"]["outcome"]
                            .as_str()
                            .unwrap_or_default()
                            .to_string();
                        state.permission_outcomes.lock().expect("lock").push(outcome.clone());

                        if scenario == "cancel" {
                            // 等客户端的 cancel 到达，再发一条权限请求：核心必须自动回 cancelled，不进前端队列。
                            let _ = cancel_rx.wait_for(|c| *c).await;
                            let late = cx.send_request(permission_request(&session_id, "call_2")).block_task().await.expect("late permission");
                            let late_outcome = serde_json::to_value(&late).expect("json")["outcome"]["outcome"]
                                .as_str()
                                .unwrap_or_default()
                                .to_string();
                            state.permission_outcomes.lock().expect("lock").push(late_outcome);
                            // cancel 之后才到的 elicitation：核心同样必须就地回 cancel、不进前端队列。
                            // 前端是按发 cancel 那一刻的队列快照逐条回的，这条它看不见——核心不代答就挂死
                            // （审查 finding，2026-09-22；permission 那半边 R1 就修了，这半边一直空着）。
                            let late_form: acp::CreateElicitationRequest = serde_json::from_value(json!({
                                "mode": "form", "sessionId": session_id, "message": "still there?",
                                "requestedSchema": { "type": "object", "properties": { "ok": { "type": "boolean" } } }
                            }))
                            .expect("late form");
                            let late_el = cx.send_request(late_form).block_task().await.expect("late elicitation");
                            state.elicitation_actions.lock().expect("lock").push(
                                serde_json::to_value(&late_el).expect("json")["action"].as_str().unwrap_or_default().to_string(),
                            );
                            responder.respond(acp::PromptResponse::new(acp::StopReason::Cancelled)).expect("respond");
                            return;
                        }

                        cx.send_notification(session_update(&session_id, json!({
                            "sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "completed"
                        })))
                        .expect("send");
                        // form 与 url 两种 elicitation，都得经 client_request 到达并由 respond 收尾。
                        let form: acp::CreateElicitationRequest = serde_json::from_value(json!({
                            "mode": "form", "sessionId": session_id, "message": "confirm?",
                            "requestedSchema": { "type": "object", "properties": { "ok": { "type": "boolean", "default": true } } }
                        }))
                        .expect("form");
                        let form_response = cx.send_request(form).block_task().await.expect("form response");
                        state.elicitation_actions.lock().expect("lock").push(
                            serde_json::to_value(&form_response).expect("json")["action"].as_str().unwrap_or_default().to_string(),
                        );
                        let url: acp::CreateElicitationRequest = serde_json::from_value(json!({
                            "mode": "url", "requestId": "auth-1", "message": "open browser",
                            "elicitationId": "el_1", "url": "https://example.invalid/login"
                        }))
                        .expect("url");
                        let url_response = cx.send_request(url).block_task().await.expect("url response");
                        state.elicitation_actions.lock().expect("lock").push(
                            serde_json::to_value(&url_response).expect("json")["action"].as_str().unwrap_or_default().to_string(),
                        );
                        cx.send_notification(
                            UntypedMessage::new("elicitation/complete", json!({ "elicitationId": "el_1", "requestId": "auth-1" }))
                                .expect("untyped"),
                        )
                        .expect("send");
                        let response: acp::PromptResponse = serde_json::from_value(json!({
                            "stopReason": "end_turn",
                            "usage": { "totalTokens": 30, "inputTokens": 20, "outputTokens": 10 }
                        }))
                        .expect("prompt response");
                        responder.respond(response).expect("respond");
                    });
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            )
            // ---- R6 会话生命周期。`session/load` 按规范先把整段历史用 `session/update` 重放完再返回；
            // `session/resume` 一条都不发。两者都在 handler 里直接发通知（不等回应，不会卡住 dispatch 循环）。
            .on_receive_request(
                async move |req: acp::ListSessionsRequest, responder: Responder<acp::ListSessionsResponse>, _cx: ConnectionTo<Client>| {
                    let cursor = req.cursor.clone();
                    list_state.lifecycle.lock().expect("lock").push(json!({
                        "method": "session/list",
                        "cwd": req.cwd.as_ref().map(|p| p.to_string_lossy().into_owned()),
                        "cursor": cursor,
                    }));
                    let cwd = req.cwd.clone().unwrap_or_else(std::env::temp_dir);
                    // 两页：第一页给 nextCursor，第二页收尾（验分页取完）。
                    let (ids, next): (Vec<&str>, Option<&str>) = match cursor.as_deref() {
                        None => (vec!["sess_fake"], Some("page2")),
                        Some("page2") => (vec!["sess_old"], None),
                        Some(_) => (vec![], None),
                    };
                    let response: acp::ListSessionsResponse = serde_json::from_value(json!({
                        "sessions": ids.iter().map(|id| json!({
                            "sessionId": id, "cwd": cwd.to_string_lossy(), "title": format!("title of {id}")
                        })).collect::<Vec<Value>>(),
                        "nextCursor": next,
                    }))
                    .expect("list response");
                    responder.respond(response)
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |req: acp::LoadSessionRequest, responder: Responder<acp::LoadSessionResponse>, cx: ConnectionTo<Client>| {
                    let session_id = req.session_id.0.to_string();
                    load_state.lifecycle.lock().expect("lock").push(json!({
                        "method": "session/load", "sessionId": session_id, "cwd": req.cwd.to_string_lossy(),
                    }));
                    for i in 0..3 {
                        cx.send_notification(session_update(&session_id, json!({
                            "sessionUpdate": "agent_message_chunk",
                            "content": { "type": "text", "text": format!("replay {i}") }
                        })))
                        .expect("send");
                    }
                    let response: acp::LoadSessionResponse = serde_json::from_value(json!({
                        "modes": { "currentModeId": "ask", "availableModes": [{ "id": "ask", "name": "Ask" }] }
                    }))
                    .expect("load response");
                    responder.respond(response)
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |req: acp::ResumeSessionRequest, responder: Responder<acp::ResumeSessionResponse>, _cx: ConnectionTo<Client>| {
                    resume_state.lifecycle.lock().expect("lock").push(json!({
                        "method": "session/resume", "sessionId": req.session_id.0.to_string(), "cwd": req.cwd.to_string_lossy(),
                    }));
                    responder.respond(acp::ResumeSessionResponse::new())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |req: acp::CloseSessionRequest, responder: Responder<acp::CloseSessionResponse>, cx: ConnectionTo<Client>| {
                    let session_id = req.session_id.0.to_string();
                    close_state.lifecycle.lock().expect("lock").push(json!({
                        "method": "session/close", "sessionId": session_id,
                    }));
                    if scenario != "close_race" {
                        return responder.respond(acp::CloseSessionResponse::new());
                    }
                    // 审查第 2 轮 P2 的场景：agent 在读到 close 之前又发了一条权限请求。
                    // 核心必须就地回 cancelled（cancel 期已置），否则这条 block_task 永远不回，
                    // close 也就永远回不去，双方挂死。
                    let state = close_state.clone();
                    tokio::spawn(async move {
                        let permission = cx
                            .send_request(permission_request(&session_id, "call_close_race"))
                            .block_task()
                            .await
                            .expect("late permission");
                        let outcome = serde_json::to_value(&permission).expect("json")["outcome"]["outcome"]
                            .as_str()
                            .unwrap_or_default()
                            .to_string();
                        state.permission_outcomes.lock().expect("lock").push(outcome);
                        responder.respond(acp::CloseSessionResponse::new()).expect("respond");
                    });
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |req: acp::DeleteSessionRequest, responder: Responder<acp::DeleteSessionResponse>, _cx: ConnectionTo<Client>| {
                    let session_id = req.session_id.0.to_string();
                    delete_state.lifecycle.lock().expect("lock").push(json!({
                        "method": "session/delete", "sessionId": session_id,
                    }));
                    if session_id == "sess_missing" {
                        responder.respond_with_error(acp::Error::new(-32602, "no such session"))
                    } else {
                        responder.respond(acp::DeleteSessionResponse::new())
                    }
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_notification(
                async move |_n: acp::CancelNotification, _cx: ConnectionTo<Client>| {
                    cancel_state.cancels.fetch_add(1, Ordering::SeqCst);
                    if let Some(tx) = cancel_state.cancel_flag.lock().expect("lock").as_ref() {
                        let _ = tx.send(true);
                    }
                    Ok(())
                },
                agent_client_protocol::on_receive_notification!(),
            )
            .connect_to(transport)
            .await;
        // 传输被客户端关掉时这里返回；错误不是断言目标。
        let _ = result;
    })
}

async fn connect(scenario: &'static str) -> (Arc<AgentConnection>, Arc<Events>, Arc<FakeState>, tokio::task::JoinHandle<()>) {
    let (client_side, agent_side) = Channel::duplex();
    let state = Arc::new(FakeState::default());
    let agent_task = spawn_fake_agent(state.clone(), agent_side, scenario);
    let events = Arc::new(Events::default());
    let connection = AgentConnection::connect_with_transport("fake".into(), LaunchSpec::new("fake-agent"), events.clone(), client_side, terminals(&events))
        .await
        .expect("connect");
    (connection, events, state, agent_task)
}

/// 终端表的出口：与 `Core` 的 `TerminalEvents` 同一形状（`{terminalId, source, bytes}` / `{…, exitStatus}`），落到同一个事件收集器。
struct EventTerminals(Arc<Events>);

impl pty::TerminalSink for EventTerminals {
    fn output(&self, id: &str, source: pty::TerminalSource, bytes: &[u8]) {
        let payload = json!({ "terminalId": id, "source": source.as_str(), "bytes": BASE64_STANDARD.encode(bytes) });
        self.0.emit(EventChannel::TerminalOutput, payload.to_string());
    }

    fn exited(&self, id: &str, source: pty::TerminalSource, status: &pty::ExitStatus) {
        let payload = json!({
            "terminalId": id,
            "source": source.as_str(),
            "exitStatus": { "exitCode": status.exit_code, "signal": status.signal },
        });
        self.0.emit(EventChannel::TerminalOutput, payload.to_string());
    }
}

fn terminals(events: &Arc<Events>) -> Arc<pty::TerminalManager> {
    Arc::new(pty::TerminalManager::new(Arc::new(EventTerminals(events.clone()))))
}

fn allow_once() -> Value {
    json!({ "outcome": { "outcome": "selected", "optionId": "allow-once" } })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn auth_required_then_full_turn_with_permission_and_elicitations() {
    let (connection, events, state, _agent_task) = connect("full").await;
    assert_eq!(events.states(), vec!["initialized"]);
    assert_eq!(connection.initialize["agentInfo"]["name"], "fake-agent");
    assert_eq!(connection.initialize["authMethods"][0]["type"], "terminal");

    // 第一次 session/new 回 -32000：错误映射 + auth_required 事件带 authMethods。
    let cwd = std::env::temp_dir();
    let err = connection.session_new(cwd.clone()).await.expect_err("auth required");
    assert!(matches!(err, CoreError::AuthRequired { .. }), "{err:?}");
    let auth_event = events
        .snapshot()
        .into_iter()
        .find(|(c, v)| *c == EventChannel::AgentState && v["state"] == "auth_required")
        .map(|(_, v)| v)
        .expect("auth_required event");
    assert_eq!(auth_event["authMethods"][0]["id"], "fake-setup");
    assert_eq!(auth_event["message"], "FAKE_KEY is not configured");

    // 重试成功。
    let session = connection.session_new(cwd.clone()).await.expect("session");
    assert_eq!(session["sessionId"], "sess_fake");
    assert_eq!(connection.shared().session_cwd("sess_fake"), Some(cwd));

    // 回合：并行地把 client_request 逐个回掉。
    let responder = {
        let connection = connection.clone();
        let events = events.clone();
        tokio::spawn(async move {
            let mut answered = 0usize;
            let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
            while answered < 3 {
                assert!(tokio::time::Instant::now() < deadline, "client requests never arrived: {:#?}", events.snapshot());
                let pending: Vec<Value> = events
                    .client_requests()
                    .into_iter()
                    .filter(|r| !r["requestId"].is_null())
                    .collect();
                if let Some(req) = pending.get(answered) {
                    let request_id = req["requestId"].as_str().expect("request id").to_string();
                    let response = match req["method"].as_str().unwrap_or_default() {
                        "session/request_permission" => allow_once(),
                        "elicitation/create" if req["params"]["mode"] == "form" => json!({ "action": "accept", "content": { "ok": true } }),
                        "elicitation/create" => json!({ "action": "accept" }),
                        other => panic!("unexpected client request {other}"),
                    };
                    // 先用错形状回一次，必须被拒并留在队列里。
                    let bad = connection.respond(&request_id, json!({ "nonsense": 1 })).expect_err("shape check");
                    assert!(matches!(bad, CoreError::InvalidArgument(_)), "{bad:?}");
                    connection.respond(&request_id, response).expect("respond");
                    answered += 1;
                } else {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            }
        })
    };
    let prompt = connection
        .session_prompt("sess_fake", json!([{ "type": "text", "text": "hi" }]))
        .await
        .expect("prompt");
    responder.await.expect("responder task");
    assert_eq!(prompt["stopReason"], "end_turn");
    assert_eq!(prompt["usage"]["totalTokens"], 30);

    // session/update 直出（SDK 类型 serde）：agent_message_chunk / tool_call / tool_call_update；notice 不在其中。
    let updates = events.updates();
    assert_eq!(updates, vec!["agent_message_chunk", "tool_call", "tool_call_update"], "{updates:?}");
    let first_update = events
        .snapshot()
        .into_iter()
        .find(|(c, _)| *c == EventChannel::SessionUpdate)
        .map(|(_, v)| v)
        .expect("update");
    assert_eq!(first_update["agentId"], "fake");
    assert_eq!(first_update["sessionId"], "sess_fake");
    assert_eq!(first_update["update"]["content"]["text"], "hello");

    // notice：计数 +1，告警事件带错误文本，后续 agent_state 事件的 droppedUpdates 也是 1。
    assert_eq!(connection.shared().dropped_updates(), 1);
    let dropped = events
        .snapshot()
        .into_iter()
        .find(|(c, v)| *c == EventChannel::AgentState && v["state"] == "update_dropped")
        .map(|(_, v)| v)
        .expect("update_dropped event");
    assert_eq!(dropped["droppedUpdates"], 1);
    assert_eq!(dropped["method"], "session/update");
    assert!(dropped["error"].as_str().is_some_and(|e| e.contains("notice")), "{dropped}");

    // client_request：权限（带 sessionId）、form elicitation（带 sessionId）、url elicitation（requestScope，无 sessionId）、
    // 然后 elicitation/complete 以 requestId null 转发。
    let requests = events.client_requests();
    let methods: Vec<&str> = requests.iter().map(|r| r["method"].as_str().unwrap_or_default()).collect();
    assert_eq!(methods, vec!["session/request_permission", "elicitation/create", "elicitation/create", "elicitation/complete"], "{methods:?}");
    assert_eq!(requests[0]["params"]["toolCall"]["toolCallId"], "call_1");
    assert_eq!(requests[1]["params"]["sessionId"], "sess_fake");
    assert!(requests[2]["params"].get("sessionId").is_none(), "{}", requests[2]);
    assert_eq!(requests[2]["params"]["url"], "https://example.invalid/login");
    assert!(requests[3]["requestId"].is_null());
    assert_eq!(requests[3]["params"]["elicitationId"], "el_1");
    assert_eq!(*state.permission_outcomes.lock().expect("lock"), vec!["selected"]);
    assert_eq!(*state.elicitation_actions.lock().expect("lock"), vec!["accept", "accept"]);
    assert!(connection.shared().pending_request_ids().is_empty());

    // 回错的 id。
    let err = connection.respond("nope", json!({})).expect_err("unknown");
    assert!(matches!(err, CoreError::UnknownRequest(_)));

    // 断开：传输结束 → exited 事件（无进程，code 为 null）。
    connection.disconnect().await;
    events.wait_for("exited", |items| items.iter().any(|(c, v)| *c == EventChannel::AgentState && v["state"] == "exited")).await;
    let exited = connection.shared().exit_info().expect("exit info");
    assert_eq!(exited.code, None);
    let err = connection.session_new(std::env::temp_dir()).await.expect_err("after exit");
    assert!(matches!(err, CoreError::Exited { .. }), "{err:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cancel_auto_answers_pending_and_late_permission_requests() {
    let (connection, events, state, _agent_task) = connect("cancel").await;
    let _ = connection.session_new(std::env::temp_dir()).await.expect_err("auth required");
    let session = connection.session_new(std::env::temp_dir()).await.expect("session");
    assert_eq!(session["sessionId"], "sess_fake");

    let canceller = {
        let connection = connection.clone();
        let events = events.clone();
        tokio::spawn(async move {
            events.wait_for("permission request", |items| items.iter().any(|(c, _)| *c == EventChannel::ClientRequest)).await;
            let result = connection.session_cancel("sess_fake").expect("cancel");
            let cancelled = result["cancelledRequestIds"].as_array().expect("array");
            assert_eq!(cancelled.len(), 1, "{result}");
        })
    };
    let prompt = connection
        .session_prompt("sess_fake", json!([{ "type": "text", "text": "hi" }]))
        .await
        .expect("prompt");
    canceller.await.expect("canceller");
    assert_eq!(prompt["stopReason"], "cancelled");
    assert_eq!(state.cancels.load(Ordering::SeqCst), 1);
    // 挂起的那条与 cancel 之后才到的那条都是 cancelled；后者从未进前端队列。
    assert_eq!(*state.permission_outcomes.lock().expect("lock"), vec!["cancelled", "cancelled"]);
    // cancel 之后才到的 elicitation 同样就地回 cancel，也没进前端队列（所以 client_requests 还是 1 条）。
    assert_eq!(*state.elicitation_actions.lock().expect("lock"), vec!["cancel"]);
    assert_eq!(events.client_requests().len(), 1);
    assert!(connection.shared().pending_request_ids().is_empty());

    // 回合之外再发一次 cancel（用户连点停止、前端收尾补发）：不能污染下一回合——
    // 第二回合的权限请求必须正常进队列、由前端回应（审查 finding：cancel_pending 曾是粘滞的）。
    connection.session_cancel("sess_fake").expect("stray cancel");
    let second_turn = {
        let connection = connection.clone();
        let events = events.clone();
        tokio::spawn(async move {
            events
                .wait_for("second permission request", |items| {
                    items.iter().filter(|(c, v)| *c == EventChannel::ClientRequest && !v["requestId"].is_null()).count() == 2
                })
                .await;
            let request_id = events.client_requests()[1]["requestId"].as_str().expect("id").to_string();
            connection.respond(&request_id, allow_once()).expect("respond");
            // 假 agent 在 cancel 场景里拿到回应后等 cancel 再收尾。
            tokio::time::sleep(Duration::from_millis(50)).await;
            connection.session_cancel("sess_fake").expect("cancel");
        })
    };
    let prompt2 = connection
        .session_prompt("sess_fake", json!([{ "type": "text", "text": "again" }]))
        .await
        .expect("prompt 2");
    second_turn.await.expect("second turn task");
    assert_eq!(prompt2["stopReason"], "cancelled");
    assert_eq!(
        *state.permission_outcomes.lock().expect("lock"),
        vec!["cancelled", "cancelled", "selected", "cancelled"],
        "second turn's first permission must reach the frontend and be answered, not auto-cancelled"
    );
    assert_eq!(*state.elicitation_actions.lock().expect("lock"), vec!["cancel", "cancel"]);
    assert_eq!(events.client_requests().len(), 2);
    connection.disconnect().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn withdrawn_request_gets_request_cancelled_response_and_leaves_the_queue() {
    let (connection, events, state, _agent_task) = connect("withdraw").await;
    let _ = connection.session_new(std::env::temp_dir()).await.expect_err("auth required");
    connection.session_new(std::env::temp_dir()).await.expect("session");
    let prompt = connection
        .session_prompt("sess_fake", json!([{ "type": "text", "text": "hi" }]))
        .await
        .expect("prompt");
    assert_eq!(prompt["stopReason"], "end_turn");
    // agent 端：第一次权限请求是它自己撤回的，收到的是 -32800，不是挂死也不是别的错误。
    assert_eq!(*state.permission_outcomes.lock().expect("lock"), vec!["request_cancelled"]);
    // 前端：先看到权限请求入队，再看到 $/cancel_request 通知（requestId null、params.requestId 归一化成同形字符串）。
    let requests = events.client_requests();
    let permission = requests.iter().find(|r| r["method"] == "session/request_permission").expect("permission request");
    let withdrawn = requests.iter().find(|r| r["method"] == "$/cancel_request").expect("cancel_request notification");
    assert!(withdrawn["requestId"].is_null());
    assert_eq!(withdrawn["params"]["requestId"], permission["requestId"]);
    assert!(withdrawn["params"]["requestId"].is_string());
    assert!(connection.shared().pending_request_ids().is_empty());
    let err = connection.respond(permission["requestId"].as_str().expect("id"), allow_once()).expect_err("already withdrawn");
    assert!(matches!(err, CoreError::UnknownRequest(_)), "{err:?}");
    connection.disconnect().await;
}

/// R4：七个 fs/* / terminal/* 回调走真实的 handler → fs / pty（规则 9：Windows 上经 PowerShell 拼命令，cwd 含空格与中文）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn fs_and_terminal_callbacks_through_the_client_handlers() {
    let (connection, events, state, _agent_task) = connect("fs_terminal").await;
    let cwd = std::env::temp_dir().join(format!("acp-core r4 会话目录-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&cwd);
    std::fs::create_dir_all(&cwd).expect("mkdir");
    let _ = connection.session_new(cwd.clone()).await.expect_err("auth required");
    connection.session_new(cwd.clone()).await.expect("session");
    let prompt = connection
        .session_prompt("sess_fake", json!([{ "type": "text", "text": "fs + terminal" }]))
        .await
        .expect("prompt");
    assert_eq!(prompt["stopReason"], "end_turn");

    let log = state.callback_log.lock().expect("lock").clone();
    let step = |name: &str| log.iter().find(|v| v["step"] == name).cloned().unwrap_or_else(|| panic!("no step {name} in {log:#?}"));

    // fs/write_text_file：文件与父目录都被创建，内容一字不差。
    assert!(step("write")["ok"].is_object() || step("write")["ok"].is_null(), "{}", step("write"));
    assert_eq!(std::fs::read_to_string(cwd.join("r4 目录").join("r4.txt")).expect("written"), "第一行\n第二行\n");
    // fs/read_text_file：1-based 的 line / limit。
    assert_eq!(step("read_line2")["ok"]["content"], "第二行\n");
    // 不存在 → -32002；cwd 之外 / 行号越界 → -32602。
    assert_eq!(step("read_missing")["error"]["code"], -32002, "{}", step("read_missing"));
    assert_eq!(step("read_outside")["error"]["code"], -32602, "{}", step("read_outside"));
    assert_eq!(step("read_beyond")["error"]["code"], -32602, "{}", step("read_beyond"));

    // 前台命令：create 拿到 id；wait 是退出码 0；output 含文本、不截断、带退出状态；退出后 kill 是空操作；
    // release 之后 output 报 -32602（id 失效）。
    let tid = step("create")["ok"]["terminalId"].as_str().expect("terminalId").to_string();
    assert!(tid.starts_with("term_"), "{tid}");
    assert_eq!(step("wait")["ok"]["exitCode"], 0, "{}", step("wait"));
    let output = step("output");
    assert!(output["ok"]["output"].as_str().is_some_and(|s| s.contains("r4-terminal-ok")), "{output}");
    assert_eq!(output["ok"]["truncated"], false);
    assert_eq!(output["ok"]["exitStatus"]["exitCode"], 0);
    assert!(step("kill_after_exit")["ok"].is_object() || step("kill_after_exit")["ok"].is_null());
    assert_eq!(step("output_after_release")["error"]["code"], -32602, "{}", step("output_after_release"));

    // 后台命令：kill 之后 wait 返回非零、output 还在、release 收尾。
    assert!(step("bg_wait")["ok"]["exitCode"] != 0, "{}", step("bg_wait"));
    assert!(step("bg_output")["ok"]["output"].as_str().is_some_and(|s| s.contains("started")), "{}", step("bg_output"));
    assert!(step("bg_output")["ok"]["exitStatus"].is_object());

    // 终端输出也经 `acp/terminal_output`（source = agent）推给了前端；release 后本连接不再持有终端。
    let terminal_events: Vec<Value> = events
        .snapshot()
        .into_iter()
        .filter(|(c, _)| *c == EventChannel::TerminalOutput)
        .map(|(_, v)| v)
        .collect();
    assert!(terminal_events.iter().any(|v| v["terminalId"] == tid.as_str() && v["source"] == "agent" && v["bytes"].is_string()), "{terminal_events:#?}");
    assert!(terminal_events.iter().any(|v| v["terminalId"] == tid.as_str() && v["exitStatus"]["exitCode"] == 0), "{terminal_events:#?}");
    assert!(connection.shared().owned_terminal_ids().is_empty());

    connection.disconnect().await;
    let _ = std::fs::remove_dir_all(&cwd);
}

/// agent 死了（或被断开）时它建的终端要一起释放，不能留孤儿进程。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn owned_terminals_are_released_when_the_agent_disconnects() {
    let (connection, _events, _state, _agent_task) = connect("full").await;
    let cwd = std::env::temp_dir();
    let _ = connection.session_new(cwd.clone()).await.expect_err("auth required");
    connection.session_new(cwd.clone()).await.expect("session");
    // 直接经 Shared 的 handler 建一个长命令的终端（与 agent 发请求走同一条路），不必再写一个 agent 场景。
    let terminals = connection.shared().terminal_manager();
    let (command, args): (&str, Vec<String>) = if cfg!(windows) {
        ("cmd", vec!["/c".into(), "ping -n 30 127.0.0.1 > nul".into()])
    } else {
        ("sh", vec!["-c".into(), "sleep 30".into()])
    };
    let id = terminals
        .spawn_shell_command(command, &args, Vec::new(), Some(cwd), None, pty::TerminalSource::Agent)
        .expect("spawn");
    connection.shared().adopt_terminal(&id);
    assert_eq!(connection.shared().owned_terminal_ids(), vec![id.clone()]);
    connection.disconnect().await;
    assert!(connection.shared().owned_terminal_ids().is_empty());
    assert!(matches!(terminals.output(&id), Err(pty::PtyError::UnknownTerminal(_))), "terminal must be released");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn initialize_failure_when_agent_side_closes_immediately() {
    let (client_side, agent_side) = Channel::duplex();
    drop(agent_side);
    let events = Arc::new(Events::default());
    let err = AgentConnection::connect_with_transport("dead".into(), LaunchSpec::new("dead"), events.clone(), client_side, terminals(&events))
        .await
        .expect_err("must fail");
    assert!(matches!(err, CoreError::Exited { .. } | CoreError::Transport(_) | CoreError::Acp { .. }), "{err:?}");
    let states = events.states();
    assert!(!states.contains(&"initialized".to_string()), "{states:?}");
}

// ---- R6 会话生命周期

/// `session/list` 分页取完、`session/load` 的整段重放经 `acp/session_update` 推出并把 cwd 记进账、
/// `session/resume` 一条 update 都不发、`close` / `delete` 之后核心忘掉这个会话（fs 越界判定不再放行）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn session_lifecycle_list_load_resume_close_delete() {
    let (connection, events, state, _agent_task) = connect("full").await;
    let cwd = std::env::temp_dir();

    // list：两页，第二页没有 nextCursor。
    let page1 = connection.session_list(Some(cwd.clone()), None).await.expect("list page 1");
    assert_eq!(page1["sessions"][0]["sessionId"], "sess_fake");
    assert_eq!(page1["sessions"][0]["title"], "title of sess_fake");
    let cursor = page1["nextCursor"].as_str().expect("nextCursor").to_string();
    let page2 = connection.session_list(Some(cwd.clone()), Some(cursor)).await.expect("list page 2");
    assert_eq!(page2["sessions"][0]["sessionId"], "sess_old");
    assert!(page2["nextCursor"].is_null(), "{page2}");

    // load：返回时整段重放已经推完；cwd 记账，fs 回调才不会把这个会话判成越界。
    let before = events.updates().len();
    let loaded = connection.session_load("sess_old", cwd.clone()).await.expect("load");
    assert_eq!(loaded["modes"]["currentModeId"], "ask");
    let replayed: Vec<Value> = events
        .snapshot()
        .into_iter()
        .filter(|(c, v)| *c == EventChannel::SessionUpdate && v["sessionId"] == "sess_old")
        .map(|(_, v)| v)
        .collect();
    assert_eq!(replayed.len(), 3, "整段历史必须在 session/load 返回前推完：{replayed:#?}");
    assert_eq!(events.updates().len(), before + 3);
    assert_eq!(connection.shared().session_cwd("sess_old"), Some(cwd.clone()));

    // resume：不重放。
    let count_before_resume = events.updates().len();
    connection.session_resume("sess_resumed", cwd.clone()).await.expect("resume");
    assert_eq!(events.updates().len(), count_before_resume, "session/resume 不得重放历史");
    assert_eq!(connection.shared().session_cwd("sess_resumed"), Some(cwd.clone()));

    // close / delete：成功后核心忘掉这个会话。
    connection.session_close("sess_resumed").await.expect("close");
    assert_eq!(connection.shared().session_cwd("sess_resumed"), None);
    connection.session_delete("sess_old").await.expect("delete");
    assert_eq!(connection.shared().session_cwd("sess_old"), None);

    let methods: Vec<String> = state
        .lifecycle
        .lock()
        .expect("lock")
        .iter()
        .filter_map(|v| v["method"].as_str().map(str::to_string))
        .collect();
    assert_eq!(
        methods,
        vec!["session/list", "session/list", "session/load", "session/resume", "session/close", "session/delete"]
    );

    connection.disconnect().await;
}

/// `session/close` 在途时 agent 又发一条权限请求：核心必须就地回 `cancelled`，
/// 不然客户端等 CloseSessionResponse、agent 等权限回应，双方挂死（审查第 2 轮 P2）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn permission_arriving_while_close_is_in_flight_is_auto_cancelled() {
    let (connection, events, state, _agent_task) = connect("close_race").await;
    let cwd = std::env::temp_dir();
    let _ = connection.session_new(cwd.clone()).await.expect_err("auth required");
    let session = connection.session_new(cwd.clone()).await.expect("session");
    let session_id = session["sessionId"].as_str().expect("sessionId").to_string();

    let before = events.client_requests().len();
    // 没有超时兜底：挂死的话这条 await 就回不来，测试超时即失败。
    connection.session_close(&session_id).await.expect("close must not hang");

    assert_eq!(
        state.permission_outcomes.lock().expect("lock").last().map(String::as_str),
        Some("cancelled"),
        "close 在途时到达的权限请求要自动回 cancelled"
    );
    assert_eq!(events.client_requests().len(), before, "自动回掉的请求不该进前端队列");
    assert_eq!(connection.shared().session_cwd(&session_id), None);
    connection.disconnect().await;
}

/// load 失败时不能留下陈旧的 cwd 记账（否则 agent 拿这个 id 调 `fs/*` 会被放行）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn failed_delete_keeps_the_error_and_load_of_unknown_session_is_not_recorded() {
    let (connection, _events, _state, _agent_task) = connect("full").await;
    let cwd = std::env::temp_dir();
    let err = connection.session_delete("sess_missing").await.expect_err("agent rejects");
    assert!(matches!(err, CoreError::Acp { .. }), "{err:?}");
    // 相对路径由 Core 挡下（连接层不校验）；这里验的是核心层。
    assert_eq!(connection.shared().session_cwd("sess_missing"), None);
    // 已经在账上的会话：load 失败不能把 cwd 换成这次失败请求的目录（R6 审查 finding P2）。
    let known_cwd = cwd.join("acp-core-r6-known");
    connection.session_load("sess_old", known_cwd.clone()).await.expect("load");
    assert_eq!(connection.shared().session_cwd("sess_old"), Some(known_cwd.clone()));
    connection.disconnect().await;
    let other = cwd.join("acp-core-r6-other");
    let err = connection.session_load("sess_old", other.clone()).await.expect_err("agent is gone");
    assert!(matches!(err, CoreError::Exited { .. } | CoreError::Transport(_) | CoreError::Acp { .. }), "{err:?}");
    assert_eq!(
        connection.shared().session_cwd("sess_old"),
        Some(known_cwd),
        "失败的 load 不得把越界判定的根换成它请求的那个目录"
    );

    // 本来不在账上的：失败后一条都不留。
    let err = connection.session_load("sess_never", other).await.expect_err("agent is gone");
    assert!(matches!(err, CoreError::Exited { .. } | CoreError::Transport(_) | CoreError::Acp { .. }), "{err:?}");
    assert_eq!(connection.shared().session_cwd("sess_never"), None);
}

/// `session/close` / `session/delete` 之前挂起的权限请求必须回 `cancelled`：
/// agent 挂在那条 JSON-RPC 上时连 close 都不会处理（R6 审查 finding high）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn close_and_delete_cancel_pending_permission_requests() {
    let (connection, events, state, _agent_task) = connect("cancel").await;
    let cwd = std::env::temp_dir();
    let _ = connection.session_new(cwd.clone()).await.expect_err("auth required");
    let session = connection.session_new(cwd.clone()).await.expect("session");
    let session_id = session["sessionId"].as_str().expect("sessionId").to_string();

    // 起一轮，等第一条权限请求进队列（"cancel" 场景里前端不回，它会一直挂着）。
    let prompt = {
        let connection = connection.clone();
        let session_id = session_id.clone();
        tokio::spawn(async move { connection.session_prompt(&session_id, json!([{ "type": "text", "text": "hi" }])).await })
    };
    events
        .wait_for("pending permission", |items| {
            items
                .iter()
                .any(|(c, v)| *c == EventChannel::ClientRequest && v["method"] == acp_core::agent::METHOD_REQUEST_PERMISSION && !v["requestId"].is_null())
        })
        .await;
    assert_eq!(connection.shared().pending_request_ids().len(), 1);

    // close 把它收掉：队列清空、agent 侧拿到 cancelled。
    let closed = connection.session_close(&session_id).await.expect("close");
    assert_eq!(closed["cancelledRequestIds"].as_array().map(Vec::len), Some(1), "{closed}");
    assert!(connection.shared().pending_request_ids().is_empty());
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        if state.permission_outcomes.lock().expect("lock").first().map(String::as_str) == Some("cancelled") {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "agent never saw the cancelled response");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    // close 之后账上没有这个会话了。
    assert_eq!(connection.shared().session_cwd(&session_id), None);


    // delete 走同一条收尾（这时已经没有挂起项，只验字段在）。
    let deleted = connection.session_delete(&session_id).await.expect("delete");
    assert_eq!(deleted["cancelledRequestIds"].as_array().map(Vec::len), Some(0), "{deleted}");

    // 这个场景的 agent 侧回合还在等客户端的 `session/cancel`（本用例不发），别 await 它；
    // 断开会让 `session/prompt` 那一路以 exited 收尾，任务随传输一起结束。
    connection.disconnect().await;
    prompt.abort();
}
