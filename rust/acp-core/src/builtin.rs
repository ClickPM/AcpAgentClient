//! 内置 agent：`dsh-acp-interactive`。
//!
//! - **`dsh-acp-interactive`**（本项目的一等 agent，`pins/upstream.json` 钉版本）：npm 包，
//!   官方 registry 里没有它，不内建就只能让用户手改 `settings.json`（所有者裁定 2026-09-17）。
//!
//! 对核心的其余部分**没有任何特殊待遇**：都只是一条 `type: custom` 的 `agent_servers` 条目，
//! 拉起、initialize、会话、权限全走和其他 agent 一样的路（CLAUDE.md 规则 2）。唯一的区别是
//! 这条条目**不落 `settings.json`**：
//! - 拉起参数是**按本机现状合成**的（看 PATH 上有没有全局安装或本地环境变量覆盖），
//!   换台机器就变，写进用户的设置文件只会留下一条过期的绝对路径；
//! - 用户也不该删掉它们（画板 70 / 50 里可见、不可删，前端据 `builtin` 标记不画删除按钮）。
//!
//! dsh 是 npm 包，本机没装也能经 `npx` 拉起，所以**一直在列**。
//!
//! 用户自己在 `settings.json` 里写过同名条目时，**他那条优先**（[`merge_from`]）——手工指到另一个
//! 构建 / 另一个版本时该生效，那条也照常可编辑、可删除。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use settings::{AgentServer, Settings};

/// dsh 的 agent id：与它在 registry / 文档 / `pins/upstream.json` 里的名字一致。
pub const DSH_AGENT_ID: &str = "dsh-acp-interactive";

/// 展示名。
const DSH_AGENT_NAME: &str = "DeepSeek Harness";

/// 全局安装（`npm i -g`）后落在 PATH 上的命令名（Windows 上是 `dsh-acp-interactive.cmd`，
/// 由 [`crate::command::lookup_program`] 按 PATHEXT 解析）。
const DSH_BIN: &str = "dsh-acp-interactive";

/// 本机没有全局安装时的退路：`npx -y <包名>@<版本>`。
/// **版本跟着 `pins/upstream.json` 的 `dsh-acp-interactive` 走（CLAUDE.md 规则 4：改版本先改 pins）。**
const DSH_PACKAGE: &str = "deepseekharness-acp-interactive@1.3.2";

/// 覆盖 dsh 可执行文件的环境变量：开发时指向本地 checkout 里的 `lib/bin.js` 包装或另一个版本。
pub const DSH_PATH_ENV: &str = "ACP_DSH_PATH";

/// dsh 自己的 logo：随包带（官方 registry 里没有这个 agent，也就没有可缓存的 `icon.svg`）。
/// 来源见 `assets/dsh-icon.svg` 的文件头。
const DSH_AGENT_ICON: &str = include_str!("../assets/dsh-icon.svg");

/// 内置条目。`_data_dir` 保留以备未来按数据目录扩展。
pub fn agents(_data_dir: &Path) -> BTreeMap<String, AgentServer> {
    let mut out = BTreeMap::new();
    let (program, args) = dsh_launch();
    out.insert(DSH_AGENT_ID.to_owned(), dsh_entry(program, args));
    out
}

/// dsh 的拉起方式，三选一（按顺序）：
///
/// 1. `ACP_DSH_PATH` 指到的**存在的**文件——开发时换成本地 checkout / 另一个版本；
/// 2. PATH 上全局安装的 `dsh-acp-interactive`（`npm i -g` 之后就有，Windows 上是 `.cmd` 包装）——
///    本机装过就直接用它，免得每次拉起都让 npx 再解析一遍包；
/// 3. 都没有就 `npx -y <钉版本>`：npx 头一回要下载，之后走 npm 缓存。这条让**没装过 dsh 的机器**
///    也能直接选它，代价是首次拉起慢、且要有 Node（缺 Node 时拉起失败，画板 50 的受管 Node 卡给下载）。
fn dsh_launch() -> (String, Vec<String>) {
    if let Some(raw) = std::env::var_os(DSH_PATH_ENV) {
        let path = PathBuf::from(raw);
        if path.is_file() {
            return (path.to_string_lossy().into_owned(), Vec::new());
        }
    }
    if let Some(path) = crate::command::lookup_program(DSH_BIN) {
        return (path.to_string_lossy().into_owned(), Vec::new());
    }
    ("npx".to_owned(), vec!["-y".to_owned(), DSH_PACKAGE.to_owned()])
}

/// dsh 的条目。`env` 留空：模型与密钥走 agent 自己的配置与 terminal auth（`--setup`），本客户端不碰。
fn dsh_entry(program: String, args: Vec<String>) -> AgentServer {
    AgentServer::Custom {
        path: program,
        args,
        env: BTreeMap::new(),
        extra: BTreeMap::from([
            ("builtin".to_owned(), serde_json::Value::Bool(true)),
            ("name".to_owned(), serde_json::Value::String(DSH_AGENT_NAME.to_owned())),
            ("iconSvg".to_owned(), serde_json::Value::String(DSH_AGENT_ICON.to_owned())),
        ]),
    }
}

/// 这个 id 是不是内置条目（前端据此不画删除按钮，核心据此拒绝删除 / 写设置）。
pub fn is_builtin(agent_id: &str) -> bool {
    agent_id == DSH_AGENT_ID
}

/// 这条 `agent_servers` 条目能不能写进 `settings.json`。
///
/// 内置条目不能：它的 `command` / `args` 是按本机现状**合成**的（dsh 看 PATH 上有没有全局安装），
/// 落盘之后用户条目优先（见 [`merge_from`]）。
/// 用户自己在 `settings.json` 里手写过同名条目时不挡 —— 那条是他自己的，编辑照常。
pub fn rejects_settings_write(agent_id: &str, user_entry_exists: bool) -> bool {
    if user_entry_exists {
        return false;
    }
    agent_id == DSH_AGENT_ID
}

/// 把内置条目并进一份从磁盘读出来的设置。
///
/// 用户设置里同名的条目**优先**，所以只填空位。
pub fn merge_into(settings: &mut Settings, data_dir: &Path) {
    merge_from(settings, agents(data_dir));
}

fn merge_from(settings: &mut Settings, builtin: BTreeMap<String, AgentServer>) {
    for (id, server) in builtin {
        settings.agent_servers.entry(id).or_insert(server);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DATA_DIR: &str = "C:/data/AcpAgentClient";

    fn data_dir() -> PathBuf {
        PathBuf::from(DATA_DIR)
    }

    /// 设置页对内置条目不画「编辑」，核心这里再挡一道（审查 finding P2，2026-09-17）。
    #[test]
    fn builtin_entry_is_not_written_to_settings_json() {
        // dsh 是内置 agent：用户没写过同名条目时挡。
        assert!(rejects_settings_write(DSH_AGENT_ID, false));
        assert!(!rejects_settings_write(DSH_AGENT_ID, true));
        // 别的 agent 一律放行。
        assert!(!rejects_settings_write("codex-acp", false));
    }

    /// dsh 是内置的一等 agent：一直在列，带 `builtin` / `name` / `iconSvg`。
    #[test]
    fn dsh_is_always_listed() {
        let agents = agents(&data_dir());
        assert!(agents.contains_key(DSH_AGENT_ID), "dsh 应当一直在内置条目里");
        match agents.get(DSH_AGENT_ID) {
            Some(AgentServer::Custom { path, args, env, extra }) => {
                assert!(!path.is_empty());
                // 三条拉起方式里只有 npx 那条带参数，且第一个参数一定是 `-y`。
                assert!(args.is_empty() || args[0] == "-y", "got {args:?}");
                assert!(env.is_empty(), "模型与密钥归 agent 自己，客户端不塞环境变量");
                assert_eq!(extra.get("builtin"), Some(&serde_json::Value::Bool(true)));
                assert_eq!(extra.get("name"), Some(&serde_json::Value::String(DSH_AGENT_NAME.into())));
                assert!(
                    extra
                        .get("iconSvg")
                        .and_then(serde_json::Value::as_str)
                        .is_some_and(|s| s.contains("<svg") && s.contains(r#"fill="currentColor""#))
                );
            }
            other => panic!("unexpected: {other:?}"),
        }
        assert!(is_builtin(DSH_AGENT_ID));
    }

    /// 三路分流里前两路（环境变量 / PATH 上的全局安装）给的是一个具体文件，条目就不该再带 npx 参数。
    #[test]
    fn dsh_entry_with_a_resolved_path_takes_no_npx_args() {
        let bin = PathBuf::from("C:/npm/dsh-acp-interactive.cmd");
        match dsh_entry(bin.to_string_lossy().into_owned(), Vec::new()) {
            AgentServer::Custom { path, args, .. } => {
                assert_eq!(PathBuf::from(&path), bin);
                assert!(args.is_empty(), "指到具体文件时不带 npx 参数");
            }
            other => panic!("unexpected: {other:?}"),
        }
    }

    /// 用户在 settings.json 里写过 dsh 时，他那条优先（内置的不覆盖）。
    #[test]
    fn user_dsh_entry_wins_over_builtin() {
        let mut settings = Settings::default();
        settings.agent_servers.insert(
            DSH_AGENT_ID.to_owned(),
            AgentServer::Custom { path: "mine".into(), args: vec![], env: BTreeMap::new(), extra: BTreeMap::new() },
        );
        merge_into(&mut settings, &data_dir());
        match settings.agent_servers.get(DSH_AGENT_ID) {
            Some(AgentServer::Custom { path, extra, .. }) => {
                assert_eq!(path, "mine");
                assert!(extra.get("builtin").is_none(), "用户自己那条不是内置的，删除按钮照常");
            }
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn builtin_is_filled_into_empty_settings() {
        let mut settings = Settings::default();
        merge_into(&mut settings, &data_dir());
        assert!(settings.agent_servers.contains_key(DSH_AGENT_ID));
    }
}
