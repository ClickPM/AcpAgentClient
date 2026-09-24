//! 内置 agent：两条。
//!
//! - **`zed-agent-acp` sidecar**（R7，docs/design.md § 8）：随包分发的可执行文件；
//! - **`dsh-acp-interactive`**（本项目的一等 agent，`pins/upstream.json` 钉版本）：npm 包，
//!   官方 registry 里没有它，不内建就只能让用户手改 `settings.json`（所有者裁定 2026-09-17）。
//!
//! 两条对核心的其余部分**没有任何特殊待遇**：都只是一条 `type: custom` 的 `agent_servers` 条目，
//! 拉起、initialize、会话、权限全走和其他 agent 一样的路（CLAUDE.md 规则 2）。唯一的区别是
//! 这两条条目**不落 `settings.json`**：
//! - 拉起参数是**按本机现状合成**的（sidecar 看应用可执行文件旁边，dsh 看 PATH 上有没有全局安装），
//!   换台机器就变，写进用户的设置文件只会留下一条过期的绝对路径；
//! - 用户也不该删掉它们（画板 70 / 50 里可见、不可删，前端据 `builtin` 标记不画删除按钮）。
//!
//! sidecar 不在（没构建 / 被裁掉）时那条整条不出现，前端因此什么都不用判（"缺失时静默不列出"）；
//! dsh 是 npm 包，本机没装也能经 `npx` 拉起，所以**一直在列**。
//!
//! 用户自己在 `settings.json` 里写过同名条目时，**他那条优先**（[`merge_from`]）——手工指到另一个
//! 构建 / 另一个版本时该生效，那条也照常可编辑、可删除。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use settings::{AgentServer, Settings};

/// 内置 sidecar 的 agent id。前端不认这个名字做任何特判，只有「不可删」用到它。
pub const ZED_AGENT_ID: &str = "zed";

/// 展示名（前端优先用条目里的 `name`，没有才退回 id）。
const ZED_AGENT_NAME: &str = "Zed Agent";

/// 可执行文件名（不含扩展名）。
const ZED_AGENT_EXE: &str = "zed-agent-acp";

/// 内置 agent 自己的 logo：Zed 的标志，和 registry 型条目那份缓存的 `icon.svg` 走同一条路
/// （`registry_list` 的 `iconSvg` → 侧栏会话项 / 线程头的 agent 标记 / 画板 70 的图标框）。
/// 内置条目不在官方 registry 里、也就没有可缓存的图标，只能随包带一份。
/// 来源见 `assets/zed-icon.svg` 的文件头（CLAUDE.md 规则 5）。
const ZED_AGENT_ICON: &str = include_str!("../assets/zed-icon.svg");

/// 覆盖 sidecar 路径的环境变量：开发时 sidecar 在 `CARGO_TARGET_DIR` 里，不在应用目录旁。
pub const SIDECAR_PATH_ENV: &str = "ACP_ZED_SIDECAR";

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

/// dsh 自己的 logo：和 sidecar 那份一样随包带（官方 registry 里没有这个 agent，也就没有可缓存的 `icon.svg`）。
/// 来源见 `assets/dsh-icon.svg` 的文件头。
const DSH_AGENT_ICON: &str = include_str!("../assets/dsh-icon.svg");

/// sidecar 的绝对路径；找不到返回 `None`。
///
/// 顺序：① `ACP_ZED_SIDECAR`（必须指向一个存在的文件）；② 应用可执行文件所在目录。
pub fn sidecar_path() -> Option<PathBuf> {
    if let Some(raw) = std::env::var_os(SIDECAR_PATH_ENV) {
        let path = PathBuf::from(raw);
        return path.is_file().then_some(path);
    }
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    let candidate = dir.join(exe_name());
    candidate.is_file().then_some(candidate)
}

fn exe_name() -> String {
    if cfg!(windows) {
        format!("{ZED_AGENT_EXE}.exe")
    } else {
        ZED_AGENT_EXE.to_owned()
    }
}

/// sidecar 自己的数据目录（threads.db / logs / prompts）在本应用数据目录下的名字。
const SIDECAR_DATA_SUBDIR: &str = "zed-agent";

/// 内置条目（sidecar 在时两条，不在时只有 dsh）。`data_dir` 是本应用的数据目录（docs/design.md § 10）。
pub fn agents(data_dir: &Path) -> BTreeMap<String, AgentServer> {
    let mut out = agents_at(sidecar_path().as_deref(), data_dir, settings::zed_import::zed_settings_path());
    let (program, args) = dsh_launch();
    out.insert(DSH_AGENT_ID.to_owned(), dsh_entry(program, args));
    out
}

/// [`agents`] 里 sidecar 那条的纯函数版本（测试用）：给定三个路径就给出条目表。
pub fn agents_at(
    path: Option<&Path>,
    data_dir: &Path,
    zed_settings: Option<PathBuf>,
) -> BTreeMap<String, AgentServer> {
    let mut out = BTreeMap::new();
    if let Some(path) = path {
        out.insert(ZED_AGENT_ID.to_owned(), entry(path, data_dir, zed_settings));
    }
    out
}

/// 拉起参数（R7 实测后的取法，docs/design.md § 8）：
///
/// - `--user-data-dir <数据目录>/zed-agent`：**不**和本机 Zed 共用 `threads.db`。共用时两边同时写
///   会让正在跑的 Zed 存线程失败（Zed 日志里的 `Sqlite call failed with code 5 … database is locked`，
///   来自 `crates/agent/src/agent.rs` 的保存路径）—— 那是用户的数据，不能拿它冒险（CLAUDE.md 规则 7）。
/// - `--zed-settings <Zed 的 settings.json>`：模型与密钥照样沿用 Zed 的配置（所有者裁定 2026-09-15）。
///   只读；Zed 不在这台机器上时不传这个参数，sidecar 按自己数据目录里的（通常没有）算，走内置默认值。
fn entry(path: &Path, data_dir: &Path, zed_settings: Option<PathBuf>) -> AgentServer {
    let mut args = vec![
        "--user-data-dir".to_owned(),
        data_dir.join(SIDECAR_DATA_SUBDIR).to_string_lossy().into_owned(),
    ];
    if let Some(zed_settings) = zed_settings.filter(|p| p.is_file()) {
        args.push("--zed-settings".to_owned());
        args.push(zed_settings.to_string_lossy().into_owned());
    }
    AgentServer::Custom {
        path: path.to_string_lossy().into_owned(),
        args,
        env: BTreeMap::new(),
        extra: BTreeMap::from([
            ("builtin".to_owned(), serde_json::Value::Bool(true)),
            ("name".to_owned(), serde_json::Value::String(ZED_AGENT_NAME.to_owned())),
            ("iconSvg".to_owned(), serde_json::Value::String(ZED_AGENT_ICON.to_owned())),
        ]),
    }
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
    match agent_id {
        ZED_AGENT_ID => sidecar_path().is_some(),
        DSH_AGENT_ID => true,
        _ => false,
    }
}

/// 这条 `agent_servers` 条目能不能写进 `settings.json`。
///
/// 内置条目不能：它的 `command` / `args` 是按本机现状**合成**的（sidecar 看应用可执行文件旁边，
/// dsh 看 PATH 上有没有全局安装），落盘之后用户条目优先（见 [`merge_from`]），合成的
/// `--user-data-dir` / `--zed-settings` 就不再生效，换台机器或把应用挪个位置那条绝对路径还会失效。
/// 用户自己在 `settings.json` 里手写过同名条目时不挡 —— 那条是他自己的，编辑照常。
pub fn rejects_settings_write(agent_id: &str, user_entry_exists: bool, sidecar_present: bool) -> bool {
    if user_entry_exists {
        return false;
    }
    match agent_id {
        ZED_AGENT_ID => sidecar_present,
        DSH_AGENT_ID => true,
        _ => false,
    }
}

/// 把内置条目并进一份从磁盘读出来的设置。
///
/// 用户设置里同名的条目**优先**（手工指向另一个 sidecar 构建时该生效），所以只填空位。
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

    #[test]
    fn missing_sidecar_is_not_listed() {
        assert!(agents_at(None, &data_dir(), None).is_empty());
        let mut settings = Settings::default();
        merge_from(&mut settings, agents_at(None, &data_dir(), None));
        assert!(settings.agent_servers.is_empty());
    }

    #[test]
    fn present_sidecar_becomes_a_custom_entry_with_isolated_data_dir() {
        let exe = PathBuf::from("C:/app/").join(exe_name());
        let agents = agents_at(Some(&exe), &data_dir(), None);
        match agents.get(ZED_AGENT_ID) {
            Some(AgentServer::Custom { path, args, env, extra }) => {
                assert_eq!(path, &exe.to_string_lossy());
                // threads.db 不跟本机 Zed 共用（见 `entry` 的注释）。
                assert_eq!(args[0], "--user-data-dir");
                assert_eq!(
                    PathBuf::from(&args[1]),
                    data_dir().join(SIDECAR_DATA_SUBDIR),
                    "sidecar 的数据目录要落在本应用数据目录下"
                );
                // Zed 的 settings.json 不在时不传 --zed-settings。
                assert_eq!(args.len(), 2, "got {args:?}");
                assert!(env.is_empty());
                assert_eq!(extra.get("builtin"), Some(&serde_json::Value::Bool(true)));
                assert_eq!(extra.get("name"), Some(&serde_json::Value::String(ZED_AGENT_NAME.into())));
                // 随包带的 Zed logo：前端按 `iconSvg` 画，没有它就退回画板的单色占位菱形。
                assert_eq!(extra.get("iconSvg"), Some(&serde_json::Value::String(ZED_AGENT_ICON.into())));
            }
            other => panic!("unexpected: {other:?}"),
        }
        // 序列化成 settings.json 的形状（前端读的就是它）。
        let value = serde_json::to_value(agents.get(ZED_AGENT_ID)).expect("serialize");
        assert_eq!(value["type"], "custom");
        assert_eq!(value["builtin"], true);
        assert_eq!(value["name"], ZED_AGENT_NAME);
        // 匹配串带上 `fill=`：光找 `currentColor` 的话文件头那句来源注释就够让断言恒真（审查 finding P2）。
        assert!(value["iconSvg"].as_str().is_some_and(|s| s.contains("<svg") && s.contains(r#"fill="currentColor""#)));
    }

    #[test]
    fn existing_zed_settings_are_passed_through() {
        let dir = std::env::temp_dir().join(format!("acp-builtin-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let zed_settings = dir.join("settings.json");
        std::fs::write(&zed_settings, b"{}").expect("write");

        let exe = PathBuf::from("C:/app/").join(exe_name());
        let agents = agents_at(Some(&exe), &data_dir(), Some(zed_settings.clone()));
        match agents.get(ZED_AGENT_ID) {
            Some(AgentServer::Custom { args, .. }) => {
                assert_eq!(args[2], "--zed-settings");
                assert_eq!(args[3], zed_settings.to_string_lossy());
            }
            other => panic!("unexpected: {other:?}"),
        }

        // 路径不存在时整对参数都不出现（不要给 sidecar 一个读不到的文件）。
        let agents = agents_at(Some(&exe), &data_dir(), Some(dir.join("nope.json")));
        match agents.get(ZED_AGENT_ID) {
            Some(AgentServer::Custom { args, .. }) => assert_eq!(args.len(), 2, "got {args:?}"),
            other => panic!("unexpected: {other:?}"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn user_entry_wins_over_builtin() {
        let exe = PathBuf::from("C:/app/").join(exe_name());
        let mut settings = Settings::default();
        settings.agent_servers.insert(
            ZED_AGENT_ID.to_owned(),
            AgentServer::Custom { path: "mine".into(), args: vec![], env: BTreeMap::new(), extra: BTreeMap::new() },
        );
        merge_from(&mut settings, agents_at(Some(&exe), &data_dir(), None));
        match settings.agent_servers.get(ZED_AGENT_ID) {
            Some(AgentServer::Custom { path, .. }) => assert_eq!(path, "mine"),
            other => panic!("unexpected: {other:?}"),
        }
    }

    /// 设置页对内置条目不画「编辑」，核心这里再挡一道（审查 finding P2，2026-09-17）。
    #[test]
    fn builtin_entry_is_not_written_to_settings_json() {
        // sidecar 在 + 用户没写过同名条目 = 挡。
        assert!(rejects_settings_write(ZED_AGENT_ID, false, true));
        // 用户自己手写过同名条目：那条归他，编辑照常。
        assert!(!rejects_settings_write(ZED_AGENT_ID, true, true));
        // sidecar 不在：根本没有内置条目这回事。
        assert!(!rejects_settings_write(ZED_AGENT_ID, false, false));
        // dsh 不看 sidecar 在不在（它是 npm 包，一直在列）。
        assert!(rejects_settings_write(DSH_AGENT_ID, false, false));
        assert!(!rejects_settings_write(DSH_AGENT_ID, true, false));
        // 别的 agent 一律放行。
        assert!(!rejects_settings_write("codex-acp", false, true));
    }

    /// dsh 是内置的第二条：没有 sidecar 也在列，带 `builtin` / `name` / `iconSvg`。
    #[test]
    fn dsh_is_always_listed_even_without_the_sidecar() {
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
                        // 同上：匹配串带 `fill=`，否则文件头的来源注释就让断言恒真（审查 finding P2）。
                        .is_some_and(|s| s.contains("<svg") && s.contains(r#"fill="currentColor""#))
                );
            }
            other => panic!("unexpected: {other:?}"),
        }
        assert!(is_builtin(DSH_AGENT_ID));
    }

    /// 三路分流里前两路（环境变量 / PATH 上的全局安装）给的是一个具体文件，条目就不该再带 npx 参数。
    /// `dsh_launch` 自己读环境变量与 PATH，测试里不改进程环境（Rust 2024 的 `set_var` 是 unsafe，规则 6）。
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
        let exe = PathBuf::from("C:/app/").join(exe_name());
        let mut settings = Settings::default();
        merge_from(&mut settings, agents_at(Some(&exe), &data_dir(), None));
        assert!(settings.agent_servers.contains_key(ZED_AGENT_ID));
    }
}
