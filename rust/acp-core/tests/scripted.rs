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
                        "agentCapabilities": { "loadSession": false },
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
                async move |_req: acp::NewSessionRequest, responder: Responder<acp::NewSessionResponse>, _cx: ConnectionTo<Client>| {
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
    let connection = AgentConnection::connect_with_transport("fake".into(), LaunchSpec::new("fake-agent"), events.clone(), client_side)
        .await
        .expect("connect");
    (connection, events, state, agent_task)
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn initialize_failure_when_agent_side_closes_immediately() {
    let (client_side, agent_side) = Channel::duplex();
    drop(agent_side);
    let events = Arc::new(Events::default());
    let err = AgentConnection::connect_with_transport("dead".into(), LaunchSpec::new("dead"), events.clone(), client_side)
        .await
        .expect_err("must fail");
    assert!(matches!(err, CoreError::Exited { .. } | CoreError::Transport(_) | CoreError::Acp { .. }), "{err:?}");
    let states = events.states();
    assert!(!states.contains(&"initialized".to_string()), "{states:?}");
}
