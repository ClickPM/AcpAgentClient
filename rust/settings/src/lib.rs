//! Zed 兼容的 `agent_servers` 设置（docs/design.md § 6 第 5 条、§ 10）：
//! `%APPDATA%/AcpAgentClient/settings.json`，`type: registry | custom`，从 Zed `settings.json` 导入（R5）。
//! R1 最小实现：读 / 写 / 按 agent 覆盖；只 `custom` 型会被拉起，`registry` 型 R5 填实。
//! R3 另加本地索引（`sessions.json` / `projects.json`，见 [`index`]）。
//! 写文件一律「临时文件 + rename」（CLAUDE.md 规则 7）；文件不存在视为空设置，不自动创建。

use std::collections::BTreeMap;
use std::fmt;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

pub mod index;
pub mod ui_state;
pub mod zed_import;

#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum SettingsError {
    Io(String),
    Json(String),
    NotImplemented(&'static str),
}

impl fmt::Display for SettingsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SettingsError::Io(e) => write!(f, "settings: io: {e}"),
            SettingsError::Json(e) => write!(f, "settings: json: {e}"),
            SettingsError::NotImplemented(round) => write!(f, "settings: not implemented until {round}"),
        }
    }
}

impl std::error::Error for SettingsError {}

/// 落盘原语在 `fs`（临时文件 + rename，规则 7）；它的 io 错误只取内层文案归 [SettingsError::Io]，
/// 不把 `fs: io:` 的 Display 前缀再套一层（对外仍是 `settings: io: <inner>`，与迁移前一致）。
impl From<fs::FsError> for SettingsError {
    fn from(e: fs::FsError) -> Self {
        match e {
            fs::FsError::Io(inner) => SettingsError::Io(inner),
            other => SettingsError::Io(other.to_string()),
        }
    }
}

pub type Result<T> = std::result::Result<T, SettingsError>;

/// `agent_servers` 的一条，与钉版本 Zed `crates/settings_content/src/agent.rs` 的 `CustomAgentServerSettings` 同形：
/// `custom` 是扁平的 `command`（程序路径字符串）+ `args` + `env`；两型都还有 `default_mode` / `default_config_options` /
/// `favorite_config_option_values`（R5 起经 `extra` 原样保留——本客户端不解释它们，但从 Zed 导入的条目不能被我们改写丢掉）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentServer {
    Registry {
        #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
        env: BTreeMap<String, String>,
        #[serde(flatten)]
        extra: BTreeMap<String, serde_json::Value>,
    },
    Custom {
        #[serde(rename = "command")]
        path: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        args: Vec<String>,
        #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
        env: BTreeMap<String, String>,
        #[serde(flatten)]
        extra: BTreeMap<String, serde_json::Value>,
    },
}

impl AgentServer {
    /// 两型共有的 `env`。
    pub fn env(&self) -> &BTreeMap<String, String> {
        match self {
            AgentServer::Registry { env, .. } | AgentServer::Custom { env, .. } => env,
        }
    }
}

/// 外观：四个字体轴各存一个 family 名（画板 70「外观」小节），加一个主题档（画板 07）。
///
/// 键名与 Zed 同形取 `ui_font_family` / `buffer_font_family`（Zed `crates/settings_content/src/theme.rs`）；
/// 两个 `*_cjk_font_family` 是本客户端自己的——Zed 没有中西文分轴，它靠系统 fallback 兜中文。
///
/// **一律 `Option`，缺省是 `None`**：默认字体名是设计 token（`lib/theme/tokens.dart`），
/// 不在这里再写一份（同 [`ui_state`] 的口径）。没存过就返回 null，由前端落到 token 上。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Appearance {
    /// 主题：`"light"` / `"dark"`（画板 07「深色 Token 对位表」）。
    ///
    /// 放在 `appearance` 段里而不是顶层 `theme`：顶层那个键是 Zed 的主题名（`"One Dark"` 这种），
    /// 从 Zed 抄过设置的用户文件里可能已经有了；本客户端不解释它，也不能把它改掉（规则 7，见
    /// `unknown_top_level_keys_survive_a_save`）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub theme: Option<String>,
    /// 界面西文。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ui_font_family: Option<String>,
    /// 界面中文（进 `fontFamilyFallback` 首项）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ui_cjk_font_family: Option<String>,
    /// 代码等宽西文。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub buffer_font_family: Option<String>,
    /// 代码等宽中文。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub buffer_cjk_font_family: Option<String>,
}

/// family 名的最大长度。真实字体家族名远短于此，这里只挡住把整个文件塞进来那种输入。
const MAX_FAMILY_LEN: usize = 128;

/// 主题档的全部合法取值。手写进文件的别的值一律当没设置（回缺省浅色），不报错。
const THEMES: [&str; 2] = ["light", "dark"];

fn sane_theme(value: Option<String>) -> Option<String> {
    let v = value?;
    let v = v.trim().to_ascii_lowercase();
    THEMES.contains(&v.as_str()).then_some(v)
}

/// 去首尾空白；空串、纯空白、超长、含控制字符的一律当没设置。
///
/// 为什么不做白名单：家族名是用户可手写的（系统里装了什么我们不知道），只能做形状校验。
fn sane_family(value: Option<String>) -> Option<String> {
    let v = value?;
    let v = v.trim();
    if v.is_empty() || v.chars().count() > MAX_FAMILY_LEN || v.chars().any(char::is_control) {
        return None;
    }
    Some(v.to_string())
}

impl Appearance {
    /// 四个轴逐个过 [`sane_family`]。读写两侧都过一遍：读是为了兜住手写的脏值，写是为了不把脏值落盘。
    #[must_use]
    pub fn sanitized(self) -> Self {
        Self {
            theme: sane_theme(self.theme),
            ui_font_family: sane_family(self.ui_font_family),
            ui_cjk_font_family: sane_family(self.ui_cjk_font_family),
            buffer_font_family: sane_family(self.buffer_font_family),
            buffer_cjk_font_family: sane_family(self.buffer_cjk_font_family),
        }
    }
}

/// `settings.json` 的顶层。
///
/// `extra` 原样保留我们不认识的顶层键（规则 7「不动用户数据」）：这份文件是用户可手写的，
/// 而 `save` 是整份覆盖写——没有 `extra` 的话，用户加的任何键都会在下一次写盘时被静默抹掉。
/// R7 之前只有改 agent 设置才写盘，所以没暴露；外观设置让写盘变频繁，必须堵上。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Settings {
    #[serde(default)]
    pub agent_servers: BTreeMap<String, AgentServer>,
    #[serde(default, skip_serializing_if = "Appearance::is_default")]
    pub appearance: Appearance,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl Appearance {
    /// 全空时不写 `appearance` 键，省得给没动过外观的用户平白多一段。
    fn is_default(&self) -> bool {
        *self == Self::default()
    }
}

/// 数据目录里的 settings 文件。
#[derive(Debug, Clone)]
pub struct SettingsStore {
    pub path: PathBuf,
}

impl SettingsStore {
    pub fn new(data_dir: PathBuf) -> Self {
        Self { path: data_dir.join("settings.json") }
    }

    /// 文件不存在 → 空设置；存在但不是合法 JSON → `Json` 错误（不覆盖、不修复）。
    pub fn load(&self) -> Result<Settings> {
        match std::fs::read_to_string(&self.path) {
            Ok(text) => serde_json::from_str(&text).map_err(|e| SettingsError::Json(format!("{}: {e}", self.path.display()))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Settings::default()),
            Err(e) => Err(SettingsError::Io(format!("{}: {e}", self.path.display()))),
        }
    }

    /// 临时文件 + rename（规则 7，`fs::write_atomic`）：先写同目录的 `settings.json.tmp-<pid>-<nanos>`，再原子替换。
    pub fn save(&self, settings: &Settings) -> Result<()> {
        let text = serde_json::to_string_pretty(settings).map_err(|e| SettingsError::Json(e.to_string()))?;
        Ok(fs::write_atomic(&self.path, text.as_bytes())?)
    }

    pub fn get(&self, agent_id: &str) -> Result<Option<AgentServer>> {
        Ok(self.load()?.agent_servers.get(agent_id).cloned())
    }

    /// 覆盖一条并落盘，返回落盘后的全量设置。
    pub fn upsert(&self, agent_id: &str, server: AgentServer) -> Result<Settings> {
        let mut settings = self.load()?;
        settings.agent_servers.insert(agent_id.to_string(), server);
        self.save(&settings)?;
        Ok(settings)
    }

    /// 读外观设置。文件读不动 / 不是合法 JSON 时**不报错**，回默认（四个轴全空）：
    /// 字体设置读不出来不该挡住启动，落回 token 默认值即可。
    pub fn appearance(&self) -> Appearance {
        self.load().map(|s| s.appearance.sanitized()).unwrap_or_default()
    }

    /// 覆盖外观设置并落盘，返回落盘后的外观。整段替换而不是合并：这一段前端一次全给
    /// （所以前端只能有一个写者，见 `lib/app/appearance_prefs.dart`）。
    pub fn set_appearance(&self, appearance: Appearance) -> Result<Appearance> {
        let mut settings = self.load()?;
        settings.appearance = appearance.sanitized();
        self.save(&settings)?;
        Ok(settings.appearance)
    }

    /// 删掉一条并落盘（不存在也算成功），返回落盘后的全量设置。
    pub fn remove(&self, agent_id: &str) -> Result<Settings> {
        let mut settings = self.load()?;
        if settings.agent_servers.remove(agent_id).is_some() {
            self.save(&settings)?;
        }
        Ok(settings)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("acp-settings-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn agent_server_schema_matches_zed_shape() {
        // 形状照 Zed settings.json 的真实条目（command 是字符串，args / env 在顶层，未知字段忽略）。
        let json = r#"{"agent_servers":{
            "dsh":{"type":"custom","command":"dsh-acp","args":["--acp"],"env":{"A":"1"},"default_mode":"ask"},
            "claude":{"type":"registry","env":{}}
        }}"#;
        let s: Settings = serde_json::from_str(json).expect("parse");
        match s.agent_servers.get("dsh") {
            Some(AgentServer::Custom { path, args, env, extra }) => {
                assert_eq!(path, "dsh-acp");
                assert_eq!(args, &vec!["--acp".to_string()]);
                assert_eq!(env.get("A").map(String::as_str), Some("1"));
                assert_eq!(extra.get("default_mode"), Some(&serde_json::Value::String("ask".into())), "未知字段原样保留");
            }
            other => panic!("unexpected: {other:?}"),
        }
        assert!(matches!(s.agent_servers.get("claude"), Some(AgentServer::Registry { .. })));
        let back = serde_json::to_value(&s).expect("serialize");
        assert_eq!(back["agent_servers"]["dsh"]["command"], "dsh-acp");
        assert_eq!(back["agent_servers"]["dsh"]["default_mode"], "ask");
        assert_eq!(back["agent_servers"]["claude"]["type"], "registry");
    }

    #[test]
    fn missing_file_is_empty_and_upsert_round_trips() {
        let dir = temp_dir("roundtrip");
        let store = SettingsStore::new(dir.clone());
        assert_eq!(store.load().expect("empty"), Settings::default());
        assert!(!store.path.exists(), "load must not create the file");

        let server = AgentServer::Custom {
            path: "C:/tools/agent.cmd".into(),
            args: vec!["--acp".into()],
            env: BTreeMap::from([("K".to_string(), "v".to_string())]),
            extra: BTreeMap::new(),
        };
        let after = store.upsert("dsh", server.clone()).expect("upsert");
        assert_eq!(after.agent_servers.get("dsh"), Some(&server));
        assert_eq!(store.get("dsh").expect("get"), Some(server));
        assert_eq!(store.get("nope").expect("get"), None);
        let after = store.remove("dsh").expect("remove");
        assert!(after.agent_servers.is_empty());
        assert!(store.remove("dsh").expect("idempotent").agent_servers.is_empty());
        // 没有残留的临时文件。
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .expect("dir")
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp-"))
            .collect();
        assert!(leftovers.is_empty(), "temp files left behind: {leftovers:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_file_is_reported_not_overwritten() {
        let dir = temp_dir("corrupt");
        std::fs::create_dir_all(&dir).expect("mkdir");
        let store = SettingsStore::new(dir.clone());
        std::fs::write(&store.path, "{ not json").expect("write");
        assert!(matches!(store.load(), Err(SettingsError::Json(_))));
        assert!(matches!(store.upsert("x", AgentServer::Registry { env: BTreeMap::new(), extra: BTreeMap::new() }), Err(SettingsError::Json(_))));
        assert_eq!(std::fs::read_to_string(&store.path).expect("read"), "{ not json");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn appearance_round_trip_and_defaults() {
        let dir = temp_dir("appearance");
        std::fs::create_dir_all(&dir).expect("mkdir");
        let store = SettingsStore::new(dir.clone());

        // 没存过 -> 全空，前端据此落回 token。
        assert_eq!(store.appearance(), Appearance::default());

        let want = Appearance {
            theme: Some("dark".into()),
            ui_font_family: Some("Inter".into()),
            ui_cjk_font_family: Some("MiSans".into()),
            buffer_font_family: Some("JetBrains Mono".into()),
            buffer_cjk_font_family: Some("Sarasa Mono SC".into()),
        };
        assert_eq!(store.set_appearance(want.clone()).expect("set"), want);
        assert_eq!(store.appearance(), want);

        // 只改主题、字体全默认，也要能独立落盘。
        let only_theme = Appearance { theme: Some("light".into()), ..Default::default() };
        assert_eq!(store.set_appearance(only_theme.clone()).expect("set"), only_theme);
        assert_eq!(store.appearance(), only_theme);

        // 全空时不写 `appearance` 键。
        store.set_appearance(Appearance::default()).expect("clear");
        let text = std::fs::read_to_string(&store.path).expect("read");
        assert!(!text.contains("appearance"), "空外观不该落键: {text}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn appearance_theme_only_takes_light_or_dark() {
        let norm = |v: &str| Appearance { theme: Some(v.into()), ..Default::default() }.sanitized().theme;
        assert_eq!(norm("dark").as_deref(), Some("dark"));
        assert_eq!(norm("  Light  ").as_deref(), Some("light"), "去空白 + 大小写不敏感");
        // 手写的别的值一律当没设置：前端落回缺省浅色，不报错也不改用户的文件。
        assert_eq!(norm("system"), None);
        assert_eq!(norm("One Dark"), None);
        assert_eq!(norm(""), None);
        assert_eq!(Appearance::default().sanitized().theme, None);
    }

    #[test]
    fn appearance_sanitizes_junk() {
        let junk = Appearance {
            theme: None,
            ui_font_family: Some("   ".into()),                       // 纯空白
            ui_cjk_font_family: Some("  MiSans  ".into()),            // 去首尾空白
            buffer_font_family: Some("a".repeat(MAX_FAMILY_LEN + 1)), // 超长
            buffer_cjk_font_family: Some("Bad\u{7}Name".into()),      // 控制字符
        }
        .sanitized();
        assert_eq!(junk.ui_font_family, None);
        assert_eq!(junk.ui_cjk_font_family.as_deref(), Some("MiSans"));
        assert_eq!(junk.buffer_font_family, None);
        assert_eq!(junk.buffer_cjk_font_family, None);
    }

    #[test]
    fn unknown_top_level_keys_survive_a_save() {
        // 规则 7：settings.json 是用户可手写的，整份覆盖写不能把我们不认识的键抹掉。
        let dir = temp_dir("extra");
        std::fs::create_dir_all(&dir).expect("mkdir");
        let store = SettingsStore::new(dir.clone());
        std::fs::write(&store.path, r#"{"theme":"One Dark","telemetry":{"diagnostics":false}}"#).expect("write");

        store.set_appearance(Appearance { ui_font_family: Some("Geist".into()), ..Default::default() }).expect("set");

        let back: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&store.path).expect("read")).expect("json");
        assert_eq!(back["theme"], serde_json::json!("One Dark"), "未知顶层键被抹掉了");
        assert_eq!(back["telemetry"]["diagnostics"], serde_json::json!(false));
        assert_eq!(back["appearance"]["ui_font_family"], serde_json::json!("Geist"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
