//! 内置 agent：随包分发的 `zed-agent-acp` sidecar（R7，docs/design.md § 8）。
//!
//! 它对核心的其余部分**没有任何特殊待遇**：只是一条 `type: custom` 的 `agent_servers` 条目，
//! 拉起、initialize、会话、权限全走和其他五个 agent 一样的路（CLAUDE.md 规则 2）。唯一的区别是
//! 这条条目**不落 `settings.json`**：
//! - 路径是「应用可执行文件旁边」，换台机器就变，写进用户的设置文件只会留下一条过期的绝对路径；
//! - 用户也不该删掉它（画板 70 里可见、不可删）。
//!
//! sidecar 不在（没构建 / 被裁掉）时整条不出现，前端因此什么都不用判（"缺失时静默不列出"）。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use settings::{AgentServer, Settings};

/// 内置 sidecar 的 agent id。前端不认这个名字做任何特判，只有「不可删」用到它。
pub const ZED_AGENT_ID: &str = "zed";

/// 展示名（前端优先用条目里的 `name`，没有才退回 id）。
const ZED_AGENT_NAME: &str = "Zed Agent";

/// 可执行文件名（不含扩展名）。
const ZED_AGENT_EXE: &str = "zed-agent-acp";

/// 覆盖 sidecar 路径的环境变量：开发时 sidecar 在 `CARGO_TARGET_DIR` 里，不在应用目录旁。
pub const SIDECAR_PATH_ENV: &str = "ACP_ZED_SIDECAR";

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

/// 内置条目（sidecar 在时一条，不在时空表）。`data_dir` 是本应用的数据目录（docs/design.md § 10）。
pub fn agents(data_dir: &Path) -> BTreeMap<String, AgentServer> {
    agents_at(sidecar_path().as_deref(), data_dir, settings::zed_import::zed_settings_path())
}

/// [`agents`] 的纯函数版本（测试用）：给定三个路径就给出条目表。
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
        ]),
    }
}

pub fn is_builtin(agent_id: &str) -> bool {
    agent_id == ZED_AGENT_ID && sidecar_path().is_some()
}

/// 这条 `agent_servers` 条目能不能写进 `settings.json`。
///
/// 内置条目不能：它的 `command` / `args` 是按可执行文件位置**合成**的，落盘之后用户条目优先
/// （见 [`merge_from`]），合成的 `--user-data-dir` / `--zed-settings` 就不再生效，换台机器或把
/// 应用挪个位置那条绝对路径还会失效。用户自己在 `settings.json` 里手写过同名条目时不挡 ——
/// 那条是他自己的，编辑照常。
pub fn rejects_settings_write(agent_id: &str, user_entry_exists: bool, sidecar_present: bool) -> bool {
    sidecar_present && !user_entry_exists && agent_id == ZED_AGENT_ID
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
            }
            other => panic!("unexpected: {other:?}"),
        }
        // 序列化成 settings.json 的形状（前端读的就是它）。
        let value = serde_json::to_value(agents.get(ZED_AGENT_ID)).expect("serialize");
        assert_eq!(value["type"], "custom");
        assert_eq!(value["builtin"], true);
        assert_eq!(value["name"], ZED_AGENT_NAME);
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

    /// 设置页对内置条目禁用「编辑」，核心这里再挡一道（审查 finding P2，2026-09-17）。
    #[test]
    fn builtin_entry_is_not_written_to_settings_json() {
        // sidecar 在 + 用户没写过同名条目 = 挡。
        assert!(rejects_settings_write(ZED_AGENT_ID, false, true));
        // 用户自己手写过同名条目：那条归他，编辑照常。
        assert!(!rejects_settings_write(ZED_AGENT_ID, true, true));
        // sidecar 不在：根本没有内置条目这回事。
        assert!(!rejects_settings_write(ZED_AGENT_ID, false, false));
        // 别的 agent 一律放行。
        assert!(!rejects_settings_write("dsh", false, true));
    }

    #[test]
    fn builtin_is_filled_into_empty_settings() {
        let exe = PathBuf::from("C:/app/").join(exe_name());
        let mut settings = Settings::default();
        merge_from(&mut settings, agents_at(Some(&exe), &data_dir(), None));
        assert!(settings.agent_servers.contains_key(ZED_AGENT_ID));
    }
}
