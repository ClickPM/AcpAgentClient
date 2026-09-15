//! terminal 型认证的拉起参数（docs/design.md § 5 第 3 条）：用 pty 以附加 args / env 重拉同一个 agent 程序；
//! 兼容旧版 `_meta.terminal-auth`（`label / command / args / env`，自带一条完整命令）。
//! Derived from zed-industries/zed crates/agent_servers/src/acp.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)
//! （`terminal_auth_task` 与 `meta_terminal_auth_task`；Zed 的一等 terminal 方法在稳定版还藏在 beta flag 后，
//! 本项目按 § 5 首选一等方法、旧版 meta 只作回退。）

use std::collections::HashMap;

use agent_client_protocol::schema::v1 as acp;
use serde::Deserialize;

use crate::command::LaunchSpec;
use crate::meta_keys::outbound;

/// 可见终端里要跑的命令。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthSpawn {
    pub label: String,
    pub program: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

#[derive(Deserialize)]
struct MetaTerminalAuth {
    label: String,
    command: String,
    #[serde(default)]
    args: Vec<String>,
    #[serde(default)]
    env: HashMap<String, String>,
}

/// 一等 `terminal` 方法：基础命令 + 方法的 `args` / `env`（后者覆盖同名变量）；
/// 其他类型的方法：只有带旧版 `terminal-auth` 元数据时才能在终端里跑，否则 `None`（走 `authenticate`）。
pub fn terminal_auth_spawn(base: &LaunchSpec, method: &acp::AuthMethod) -> Option<AuthSpawn> {
    match method {
        acp::AuthMethod::Terminal(terminal) => {
            let mut env: Vec<(String, String)> = base.env.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
            for (k, v) in &terminal.env {
                env.retain(|(existing, _)| existing != k);
                env.push((k.clone(), v.clone()));
            }
            let mut args = base.args.clone();
            args.extend(terminal.args.iter().cloned());
            Some(AuthSpawn {
                label: terminal.name.clone(),
                program: base.program.clone(),
                args,
                env,
            })
        }
        other => legacy_meta_spawn(other),
    }
}

fn legacy_meta_spawn(method: &acp::AuthMethod) -> Option<AuthSpawn> {
    let meta = method.meta()?;
    let value = meta.get(outbound::TERMINAL_AUTH)?.clone();
    let parsed = serde_json::from_value::<MetaTerminalAuth>(value).ok()?;
    let mut env: Vec<(String, String)> = parsed.env.into_iter().collect();
    env.sort();
    Some(AuthSpawn {
        label: parsed.label,
        program: parsed.command,
        args: parsed.args,
        env,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn base() -> LaunchSpec {
        let mut spec = LaunchSpec::new(r"C:\Users\me\AppData\Roaming\npm\dsh-acp-interactive.cmd");
        spec.args = vec!["--acp".into()];
        spec.env.insert("DSH_HOME".into(), "D:/home".into());
        spec.env.insert("KEEP".into(), "1".into());
        spec
    }

    #[test]
    fn first_class_terminal_method_appends_args_and_overrides_env() {
        let method: acp::AuthMethod = serde_json::from_value(json!({
            "type": "terminal", "id": "dsh-setup", "name": "Configure DeepSeek API key",
            "args": ["--setup"], "env": {"DSH_HOME": "D:/other"}
        }))
        .expect("method");
        let spawn = terminal_auth_spawn(&base(), &method).expect("spawn");
        assert_eq!(spawn.label, "Configure DeepSeek API key");
        assert_eq!(spawn.program, base().program);
        assert_eq!(spawn.args, vec!["--acp".to_string(), "--setup".to_string()]);
        assert!(spawn.env.contains(&("DSH_HOME".to_string(), "D:/other".to_string())));
        assert!(spawn.env.contains(&("KEEP".to_string(), "1".to_string())));
        assert_eq!(spawn.env.iter().filter(|(k, _)| k == "DSH_HOME").count(), 1);
    }

    /// 测试里 `_meta` 字段名单独成行、键来自 meta_keys 常量（validate.ps1 的规则 2 检查）。
    const META_FIELD: &str = "_meta";

    fn with_legacy_terminal_auth(inner: serde_json::Value) -> acp::AuthMethod {
        let mut meta = serde_json::Map::new();
        meta.insert(outbound::TERMINAL_AUTH.to_string(), inner);
        let mut method = json!({"id": "legacy", "name": "Login"});
        method[META_FIELD] = serde_json::Value::Object(meta);
        serde_json::from_value(method).expect("method")
    }

    #[test]
    fn agent_method_with_legacy_terminal_auth_runs_its_own_command() {
        let method = with_legacy_terminal_auth(json!({"label": "gemini /auth", "command": "node", "args": ["bin.js", "--setup"], "env": {"A": "1"}}));
        let spawn = terminal_auth_spawn(&base(), &method).expect("spawn");
        assert_eq!(spawn.label, "gemini /auth");
        assert_eq!(spawn.program, "node");
        assert_eq!(spawn.args, vec!["bin.js".to_string(), "--setup".to_string()]);
        assert_eq!(spawn.env, vec![("A".to_string(), "1".to_string())]);
    }

    #[test]
    fn plain_agent_method_is_not_a_terminal_method() {
        let method = with_legacy_terminal_auth(json!({"nope": true}));
        assert!(terminal_auth_spawn(&base(), &method).is_none());
        let bare: acp::AuthMethod = serde_json::from_value(json!({"id": "agent", "name": "Login"})).expect("method");
        assert!(terminal_auth_spawn(&base(), &bare).is_none());
    }
}
