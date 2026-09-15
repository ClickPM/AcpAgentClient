//! agent 子进程的拉起参数与 Windows 细节（CLAUDE.md 规则 9）：
//! - `settings.json` 的 `custom` 条目 → [`LaunchSpec`]（R5 起 registry 型也落到这里）；
//! - 裸程序名按 PATH + PATHEXT 解析成带扩展名的路径（Rust std 只找 `.exe`，`npx` / `dsh-acp-interactive` 这类
//!   `.cmd` 包装找不到）；解析到 `.cmd` / `.bat` 后由 std 经 `cmd.exe /c` 带引号拉起（Rust ≥ 1.77 的 BatBadBut 修复）；
//! - GUI 宿主里不弹控制台窗口（`CREATE_NO_WINDOW`）；
//! - 结束进程树：Windows 用 `taskkill /T`（`.cmd` 包装的 `cmd.exe` 被杀后 node 子进程会成孤儿），其他平台 `kill`。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use settings::AgentServer;

use crate::error::{CoreError, Result};

/// Windows `CREATE_NO_WINDOW`（`processthreadsapi.h`）。
#[cfg(windows)]
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// 一个 agent 程序的拉起方式：程序（原样，解析在拉起时做）、参数、附加环境变量。
/// terminal auth 用同一份追加 `AuthMethodTerminal.args / env`（docs/design.md § 5）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchSpec {
    pub program: String,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
}

impl LaunchSpec {
    pub fn new(program: impl Into<String>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            env: BTreeMap::new(),
        }
    }

    /// `agent_servers` 的一条 → 拉起参数。R1 只有 `custom`；`registry` 型等 R5 的安装与 Node 解析。
    pub fn from_server(agent_id: &str, server: &AgentServer) -> Result<Self> {
        match server {
            AgentServer::Custom { path, args, env } => {
                if path.trim().is_empty() {
                    return Err(CoreError::InvalidArgument(format!("agent `{agent_id}`: command is empty")));
                }
                Ok(Self {
                    program: path.clone(),
                    args: args.clone(),
                    env: env.clone(),
                })
            }
            AgentServer::Registry { .. } => Err(CoreError::NotImplemented("R5")),
        }
    }
}

/// 裸程序名 → PATH 里带扩展名的路径。已含路径分隔符或是绝对路径的原样返回；找不到也原样返回（让 spawn 报错）。
/// Windows 按 `PATHEXT`（默认 `.COM;.EXE;.BAT;.CMD`）逐个试；有扩展名的名字只试精确匹配。
pub fn resolve_program(program: &str) -> PathBuf {
    let path = Path::new(program);
    if path.is_absolute() || path.components().count() > 1 {
        return path.to_path_buf();
    }
    let Some(path_var) = std::env::var_os("PATH") else {
        return path.to_path_buf();
    };
    let candidates: Vec<String> = candidate_names(program);
    for dir in std::env::split_paths(&path_var) {
        if dir.as_os_str().is_empty() {
            continue;
        }
        for name in &candidates {
            let candidate = dir.join(name);
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    path.to_path_buf()
}

fn candidate_names(program: &str) -> Vec<String> {
    if !cfg!(windows) || Path::new(program).extension().is_some() {
        return vec![program.to_string()];
    }
    let exts = std::env::var("PATHEXT")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| ".COM;.EXE;.BAT;.CMD".to_string());
    exts.split(';')
        .map(str::trim)
        .filter(|e| e.starts_with('.'))
        .map(|e| format!("{program}{}", e.to_ascii_lowercase()))
        .collect()
}

/// 三路管道、kill_on_drop、无控制台窗口。`cwd` 是 agent 进程的工作目录（第一个会话的项目目录；dsh 把会话存在 cwd 下）。
pub fn build_command(spec: &LaunchSpec, cwd: Option<&Path>) -> tokio::process::Command {
    let program = resolve_program(&spec.program);
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(&spec.args)
        .envs(&spec.env)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    if let Some(cwd) = cwd {
        cmd.current_dir(cwd);
    }
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);
    cmd
}

/// 结束整棵进程树。Windows：`taskkill /F /T /PID`（不引 Job Object，那需要 unsafe，规则 6），再 `kill` 兜底。
pub async fn kill_tree(child: &mut tokio::process::Child) {
    #[cfg(windows)]
    if let Some(pid) = child.id() {
        let mut cmd = tokio::process::Command::new("taskkill");
        cmd.args(["/F", "/T", "/PID", &pid.to_string()])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .creation_flags(CREATE_NO_WINDOW);
        let _ = cmd.status().await;
    }
    let _ = child.start_kill();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absolute_and_relative_paths_pass_through() {
        let abs = if cfg!(windows) { r"C:\tools\agent.cmd" } else { "/usr/bin/agent" };
        assert_eq!(resolve_program(abs), PathBuf::from(abs));
        assert_eq!(resolve_program("./bin/agent"), PathBuf::from("./bin/agent"));
    }

    #[test]
    fn unknown_bare_name_is_returned_unchanged() {
        assert_eq!(resolve_program("definitely-not-a-program-acp-r1"), PathBuf::from("definitely-not-a-program-acp-r1"));
    }

    #[cfg(windows)]
    #[test]
    fn bare_name_resolves_through_pathext_on_windows() {
        // cmd 一定在 PATH 上；裸名要解析到 cmd.exe（不是找不到）。
        let resolved = resolve_program("cmd");
        assert!(resolved.is_absolute(), "{resolved:?}");
        assert!(resolved.to_string_lossy().to_ascii_lowercase().ends_with("cmd.exe"), "{resolved:?}");
        // 带扩展名的名字只做精确匹配。
        let exact = resolve_program("cmd.exe");
        assert_eq!(exact, resolved);
    }

    #[test]
    fn launch_spec_from_custom_only() {
        let custom = AgentServer::Custom {
            path: "agent".into(),
            args: vec!["--acp".into()],
            env: BTreeMap::from([("A".to_string(), "1".to_string())]),
        };
        let spec = LaunchSpec::from_server("x", &custom).expect("custom");
        assert_eq!(spec.program, "agent");
        assert_eq!(spec.args, vec!["--acp".to_string()]);
        assert_eq!(spec.env.get("A").map(String::as_str), Some("1"));
        let registry = AgentServer::Registry { env: BTreeMap::new() };
        assert!(matches!(LaunchSpec::from_server("x", &registry), Err(CoreError::NotImplemented("R5"))));
        let empty = AgentServer::Custom { path: " ".into(), args: vec![], env: BTreeMap::new() };
        assert!(matches!(LaunchSpec::from_server("x", &empty), Err(CoreError::InvalidArgument(_))));
    }
}
