//! `agent::ThreadEvent` → ACP `session/update` 的翻译，以及终端输出的转发。
//!
//! Derived from zed-industries/zed crates/agent/src/agent.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)
//! （参考转写：事件到 ACP 的对应关系照 `NativeAgentConnection::handle_thread_events`，但那边的落点是
//! 进程内的 `AcpThread` 实体，这里的落点是线上的 `session/update` 通知 —— 前端才是 AcpThread 的角色。）
//!
//! 两个要点：
//! 1. **终端不走 `terminal/create`。** Zed 的终端是在 agent 进程内跑的（`acp_thread::AcpThread::create_terminal`
//!    用 `terminal` crate），客户端并没有这个终端的句柄，所以不能用 `terminal/*` 那套。按 docs/design.md § 4
//!    的「终端 provider 通道」发 `_meta.terminal_info / terminal_output / terminal_exit` 三键 —— 这正是
//!    Zed 自己作为客户端时读的三键（`agent_servers/acp.rs` 的 pre/post-handle），钉版本的 claude-agent-acp、
//!    dsh、codex 也都这么发，前端投影层按键存在处理、不按 agent 名判（CLAUDE.md 规则 2）。
//! 2. **`_meta` 键只有这三个**，都在 § 4 清单内；不自造新键。

use agent_client_protocol::schema::v1 as acp;
use gpui::{App, Entity};
use serde_json::{Value, json};

use crate::meta_keys;

/// `_meta.terminal_info`：告诉客户端「这条工具调用里嵌了一个 agent 进程内的终端」。
pub fn terminal_info_meta(terminal_id: &acp::TerminalId, cwd: Option<&std::path::Path>) -> acp::Meta {
    let mut info = serde_json::Map::new();
    info.insert(meta_keys::TERMINAL_ID_FIELD.to_owned(), json!(terminal_id.to_string()));
    if let Some(cwd) = cwd {
        info.insert("cwd".to_owned(), json!(cwd.to_string_lossy()));
    }
    meta_with(meta_keys::TERMINAL_INFO, Value::Object(info))
}

/// `_meta.terminal_output`：**追加**语义的一段输出（不是全量快照）。
pub fn terminal_output_meta(terminal_id: &acp::TerminalId, data: &str) -> acp::Meta {
    let mut output = serde_json::Map::new();
    output.insert(meta_keys::TERMINAL_ID_FIELD.to_owned(), json!(terminal_id.to_string()));
    output.insert("data".to_owned(), json!(data));
    meta_with(meta_keys::TERMINAL_OUTPUT, Value::Object(output))
}

/// `_meta.terminal_exit`：`exit_code` 与 `signal` 都可缺省。
pub fn terminal_exit_meta(terminal_id: &acp::TerminalId, status: &acp::TerminalExitStatus) -> acp::Meta {
    let mut exit = serde_json::Map::new();
    exit.insert(meta_keys::TERMINAL_ID_FIELD.to_owned(), json!(terminal_id.to_string()));
    if let Some(code) = status.exit_code {
        exit.insert("exit_code".to_owned(), json!(code));
    }
    if let Some(signal) = &status.signal {
        exit.insert("signal".to_owned(), json!(signal));
    }
    meta_with(meta_keys::TERMINAL_EXIT, Value::Object(exit))
}

fn meta_with(key: &str, value: Value) -> acp::Meta {
    // `acp::Meta` 就是 `serde_json::Map<String, Value>` 的别名。
    let mut map = acp::Meta::new();
    map.insert(key.to_owned(), value);
    map
}

/// `acp_thread::Diff` → 线上的 `ToolCallContent::Diff`。
///
/// `Diff::base_text()` 是编辑前的全文，`buffer` 是编辑后的实时内容；两者都给，客户端（画板 21）
/// 自己算行级差异。没有文件路径的（还没落到某个 buffer）整条跳过，而不是编造一个路径。
///
/// `Diff::file_path` 给的是 worktree 相对路径（`full_path`），而 ACP 的 `Diff.path` 要绝对路径
/// —— 客户端的「在文件面板里定位」按那条路径开文件（R4）。所以相对路径在这里拼上会话的 cwd。
pub fn diff_content(
    diff: &Entity<acp_thread::Diff>,
    cwd: &std::path::Path,
    cx: &App,
) -> Option<acp::ToolCallContent> {
    let diff = diff.read(cx);
    let path = std::path::PathBuf::from(diff.file_path(cx)?);
    let path = if path.is_absolute() {
        path
    } else {
        // `full_path` 的第一段是 worktree 根的名字，而 cwd 已经指向那个根，去掉一段免得重复。
        let relative = path
            .strip_prefix(cwd.file_name().map(std::path::Path::new).unwrap_or(&path))
            .unwrap_or(&path);
        cwd.join(relative)
    };
    let new_text = diff.buffer().read(cx).text();
    Some(acp::ToolCallContent::Diff(
        acp::Diff::new(path, new_text).old_text(Some(diff.base_text().to_string())),
    ))
}

/// `acp_thread::PermissionOptions` → 线上的扁平选项表。
///
/// Zed 的下拉型（`Dropdown` / `DropdownWithPatterns`）每个 choice 是一对 allow / deny；ACP v1 的
/// `session/request_permission` 只有一维选项表（画板 25 就是一排按钮），所以按 allow 全部在前、
/// deny 全部在后摊平，顺序稳定。pattern 勾选那套是 Zed UI 独有的，这里不投影（对端拿不到它）。
///
/// **按 `optionId` 去重**：Zed 的 pattern 型下拉会给多个 choice 用**同一个** optionId，靠 UI 里的
/// 勾选框区分作用范围（R7 实测：`always_allow:terminal` 同时叫「Always for terminal」和
/// 「Always for `echo …` commands」）。线上只有 optionId 能回指，重复的 id 会让「只对这条命令永久允许」
/// 被当成「对整个 terminal 工具永久允许」—— 授权范围比用户点的**更大**，所以只保留第一次出现的那个。
pub fn permission_options(options: &acp_thread::PermissionOptions) -> Vec<acp::PermissionOption> {
    let flat = match options {
        acp_thread::PermissionOptions::Flat(options) => options.clone(),
        acp_thread::PermissionOptions::Dropdown(choices) => flatten_choices(choices),
        acp_thread::PermissionOptions::DropdownWithPatterns { choices, .. } => {
            flatten_choices(choices)
        }
    };
    let mut seen = std::collections::HashSet::new();
    flat.into_iter()
        .filter(|option| seen.insert(option.option_id.clone()))
        .collect()
}

fn flatten_choices(choices: &[acp_thread::PermissionOptionChoice]) -> Vec<acp::PermissionOption> {
    let mut out = Vec::with_capacity(choices.len() * 2);
    out.extend(choices.iter().map(|choice| choice.allow.clone()));
    out.extend(choices.iter().map(|choice| choice.deny.clone()));
    out
}

/// 终端输出的增量跟踪。
///
/// `acp_thread::Terminal::current_output` 给的是**全量快照**（Zed 在超过 `output_byte_limit` 时从
/// **尾部**截断、保留开头），而 `_meta.terminal_output` 是追加语义，所以这里把快照差成增量。
///
/// 正常情况下新快照以旧快照为前缀，直接取后缀即可。交互式程序用 `\r` 回改同一行、或清屏时，
/// 前缀会不成立；这时退回「找最长的『旧尾 == 新头』重叠」，重叠之外的部分补发。完全对不上就整份补发
/// （宁可重复也不丢输出 —— 前端的 `TerminalBuffer` 是纯追加的，丢了就再也补不回来）。
///
/// **调用方要先把快照的尾部空白去掉**（`trim_end`）：Zed 的 `get_content()` 会把整个 PTY 网格
/// 连同末尾的空行一起给出来，不去掉的话第一帧就是一串 `\n`，下一帧的真实输出接在前面、前缀不成立，
/// 于是整份重发（R7 实测：客户端先收到 5 个空行，再收到「5 个空行 + 正文」）。
#[derive(Default)]
pub struct OutputTracker {
    sent: String,
}

/// 重叠搜索的上限，避免长输出上退化成 O(n²)。
const OVERLAP_SCAN_LIMIT: usize = 8 * 1024;

impl OutputTracker {
    /// 返回这次要追加的片段；没有新东西时返回 `None`。
    pub fn delta(&mut self, snapshot: &str) -> Option<String> {
        if snapshot == self.sent {
            return None;
        }
        if let Some(rest) = snapshot.strip_prefix(self.sent.as_str()) {
            let rest = rest.to_owned();
            self.sent = snapshot.to_owned();
            return if rest.is_empty() { None } else { Some(rest) };
        }

        let scan_from = self.sent.len().saturating_sub(OVERLAP_SCAN_LIMIT);
        let tail = char_aligned(&self.sent, scan_from);
        let mut overlap = 0;
        for len in (1..=tail.len().min(snapshot.len())).rev() {
            if !tail.is_char_boundary(tail.len() - len) || !snapshot.is_char_boundary(len) {
                continue;
            }
            if tail[tail.len() - len..] == snapshot[..len] {
                overlap = len;
                break;
            }
        }
        self.sent = snapshot.to_owned();
        let rest = snapshot[overlap..].to_owned();
        if rest.is_empty() { None } else { Some(rest) }
    }
}

fn char_aligned(text: &str, mut from: usize) -> &str {
    while from < text.len() && !text.is_char_boundary(from) {
        from += 1;
    }
    &text[from.min(text.len())..]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delta_returns_appended_suffix() {
        let mut tracker = OutputTracker::default();
        assert_eq!(tracker.delta("abc").as_deref(), Some("abc"));
        assert_eq!(tracker.delta("abcdef").as_deref(), Some("def"));
        assert_eq!(tracker.delta("abcdef"), None);
    }

    #[test]
    fn delta_recovers_from_head_truncation_via_overlap() {
        let mut tracker = OutputTracker::default();
        assert_eq!(tracker.delta("hello world").as_deref(), Some("hello world"));
        // 头部被砍掉之后再追加：重叠是 "world"，只补发 "!!!"
        assert_eq!(tracker.delta("world!!!").as_deref(), Some("!!!"));
    }

    #[test]
    fn delta_resends_everything_when_nothing_overlaps() {
        let mut tracker = OutputTracker::default();
        assert_eq!(tracker.delta("aaaa").as_deref(), Some("aaaa"));
        assert_eq!(tracker.delta("zzzz").as_deref(), Some("zzzz"));
    }

    #[test]
    fn delta_keeps_char_boundaries_with_multibyte_output() {
        let mut tracker = OutputTracker::default();
        assert_eq!(tracker.delta("你好").as_deref(), Some("你好"));
        assert_eq!(tracker.delta("你好世界").as_deref(), Some("世界"));
    }

    #[test]
    fn permission_options_flatten_allows_then_denies_and_dedupe_by_id() {
        let choice = |allow_id: &str, allow_name: &str, deny_id: &str, deny_name: &str| {
            acp_thread::PermissionOptionChoice {
                allow: acp::PermissionOption::new(
                    acp::PermissionOptionId::new(allow_id),
                    allow_name,
                    acp::PermissionOptionKind::AllowAlways,
                ),
                deny: acp::PermissionOption::new(
                    acp::PermissionOptionId::new(deny_id),
                    deny_name,
                    acp::PermissionOptionKind::RejectAlways,
                ),
                sub_patterns: Vec::new(),
            }
        };
        // Zed 实测的形状：两个 choice 共用同一对 optionId，只有名字不同。
        let options = acp_thread::PermissionOptions::Dropdown(vec![
            choice("always_allow:terminal", "Always for terminal", "always_deny:terminal", "Always for terminal"),
            choice("always_allow:terminal", "Always for `echo hi`", "always_deny:terminal", "Always for `echo hi`"),
        ]);
        let flat = permission_options(&options);
        let ids: Vec<String> = flat.iter().map(|o| o.option_id.to_string()).collect();
        assert_eq!(ids, vec!["always_allow:terminal", "always_deny:terminal"]);
        assert_eq!(flat[0].kind, acp::PermissionOptionKind::AllowAlways);
        assert_eq!(flat[1].kind, acp::PermissionOptionKind::RejectAlways);
    }

    #[test]
    fn terminal_exit_meta_omits_absent_fields() {
        let status = acp::TerminalExitStatus::new().exit_code(Some(0u32));
        // id 先绑到变量：validate.ps1 的规则 2 扫描会把「同一行里既有 _meta 又有字符串字面量」判成
        // 硬编码 `_meta` 键，而这里的 `terminal_exit_meta(...)` 恰好撞上函数名里的 `_meta`。
        let terminal_id = acp::TerminalId::new("t1");
        let meta = terminal_exit_meta(&terminal_id, &status);
        let value = serde_json::to_value(&meta).unwrap();
        let exit = &value[meta_keys::TERMINAL_EXIT];
        assert_eq!(exit[meta_keys::TERMINAL_ID_FIELD], json!("t1"));
        assert_eq!(exit["exit_code"], json!(0));
        assert!(exit.get("signal").is_none());
    }
}
