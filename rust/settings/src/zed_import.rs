//! 从 Zed 的 `settings.json` 导入 `agent_servers`（docs/design.md § 6 第 5 条，画板 70）。只读 Zed 的文件（规则 7），
//! 写的是我们自己的 settings.json。Zed 的文件是 JSONC（注释 + 尾随逗号），这里自己去掉，不引 serde_json_lenient。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::Value;

use crate::{AgentServer, Result, SETTINGS_WRITES, Settings, SettingsError, SettingsStore, write_lock};

/// Zed 的 settings.json 位置：Windows `%APPDATA%\Zed\settings.json`，macOS / Linux `~/.config/zed/settings.json`
/// （`XDG_CONFIG_HOME` 优先）。
pub fn zed_settings_path() -> Option<PathBuf> {
    if cfg!(windows) {
        let appdata = std::env::var_os("APPDATA")?;
        return Some(PathBuf::from(appdata).join("Zed").join("settings.json"));
    }
    if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME").filter(|s| !s.is_empty()) {
        return Some(PathBuf::from(xdg).join("zed").join("settings.json"));
    }
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(".config").join("zed").join("settings.json"))
}

/// 导入结果：`imported` 新写进去的 id、`skipped` 因同名跳过的 id、`invalid` 解不开的条目。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ImportReport {
    pub path: String,
    pub imported: Vec<String>,
    pub skipped: Vec<String>,
    pub invalid: Vec<String>,
}

/// 去掉 `//` 与 `/* */` 注释和尾随逗号，字符串里的内容原样保留。
pub fn strip_jsonc(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    let mut in_string = false;
    while i < chars.len() {
        let c = chars[i];
        if in_string {
            out.push(c);
            if c == '\\' && i + 1 < chars.len() {
                out.push(chars[i + 1]);
                i += 2;
                continue;
            }
            if c == '"' {
                in_string = false;
            }
            i += 1;
            continue;
        }
        match c {
            '"' => {
                in_string = true;
                out.push(c);
                i += 1;
            }
            '/' if chars.get(i + 1) == Some(&'/') => {
                while i < chars.len() && chars[i] != '\n' {
                    i += 1;
                }
            }
            '/' if chars.get(i + 1) == Some(&'*') => {
                i += 2;
                while i + 1 < chars.len() && !(chars[i] == '*' && chars[i + 1] == '/') {
                    i += 1;
                }
                i += 2;
            }
            ',' => {
                // 尾随逗号：后面（跳过空白与注释）紧跟 `}` / `]` 就丢掉。
                let mut j = i + 1;
                loop {
                    while j < chars.len() && chars[j].is_whitespace() {
                        j += 1;
                    }
                    if chars.get(j) == Some(&'/') && chars.get(j + 1) == Some(&'/') {
                        while j < chars.len() && chars[j] != '\n' {
                            j += 1;
                        }
                        continue;
                    }
                    if chars.get(j) == Some(&'/') && chars.get(j + 1) == Some(&'*') {
                        j += 2;
                        while j + 1 < chars.len() && !(chars[j] == '*' && chars[j + 1] == '/') {
                            j += 1;
                        }
                        j += 2;
                        continue;
                    }
                    break;
                }
                if !matches!(chars.get(j), Some('}') | Some(']')) {
                    out.push(',');
                }
                i += 1;
            }
            _ => {
                out.push(c);
                i += 1;
            }
        }
    }
    out
}

/// 读 Zed 的 `agent_servers`（JSONC）。文件不存在 → `Io`；解不开 → `Json`。
pub fn read_zed_agent_servers(path: &Path) -> Result<BTreeMap<String, Value>> {
    let text = std::fs::read_to_string(path).map_err(|e| SettingsError::Io(format!("{}: {e}", path.display())))?;
    let value: Value = serde_json::from_str(&strip_jsonc(&text)).map_err(|e| SettingsError::Json(format!("{}: {e}", path.display())))?;
    Ok(match value.get("agent_servers") {
        Some(Value::Object(map)) => map.iter().map(|(k, v)| (k.clone(), v.clone())).collect(),
        _ => BTreeMap::new(),
    })
}

impl SettingsStore {
    /// 导入：custom 与 registry 两型都按 Zed 同形写进来（`command` / `args` / `env` / `default_config_options` …），
    /// 同名不覆盖（验收 4）；解不开的条目记 `invalid`。一条都没新增时不写文件。
    pub fn import_zed(&self, zed_path: &Path) -> Result<ImportReport> {
        let servers = read_zed_agent_servers(zed_path)?;
        let _writing = write_lock(&SETTINGS_WRITES);
        let mut settings: Settings = self.load()?;
        let mut report = ImportReport { path: zed_path.to_string_lossy().into_owned(), ..Default::default() };
        for (id, raw) in servers {
            if settings.agent_servers.contains_key(&id) {
                report.skipped.push(id);
                continue;
            }
            match serde_json::from_value::<AgentServer>(raw) {
                Ok(server) => {
                    settings.agent_servers.insert(id.clone(), server);
                    report.imported.push(id);
                }
                Err(_) => report.invalid.push(id),
            }
        }
        if !report.imported.is_empty() {
            self.save(&settings)?;
        }
        Ok(report)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_comments_and_trailing_commas_but_not_strings() {
        let src = r#"{
  // 行注释
  "a": "http://x/y", /* 块注释 */
  "b": ["1", "2",],
  "c": "带 // 的字符串 /* 也不动 */",
  "d": "转义 \" 引号",
}"#;
        let v: Value = serde_json::from_str(&strip_jsonc(src)).expect("valid json after strip");
        assert_eq!(v["a"], "http://x/y");
        assert_eq!(v["b"].as_array().map(Vec::len), Some(2));
        assert_eq!(v["c"], "带 // 的字符串 /* 也不动 */");
        assert_eq!(v["d"], "转义 \" 引号");
    }

    #[test]
    fn imports_without_overwriting_same_names() {
        let dir = std::env::temp_dir().join(format!("acp-settings-zed-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("mkdir");
        let zed = dir.join("zed-settings.json");
        std::fs::write(
            &zed,
            r#"{
  "agent_servers": {
    "cursor": { "type": "registry" },
    "codex-acp": { "default_config_options": { "mode": "agent" }, "type": "registry" },
    "dsh-acp-interactive": {
      "default_config_options": { "model": "deepseek-official:deepseek-flash" },
      "type": "custom",
      "command": "C:/Users/me/AppData/Roaming/npm/dsh-acp-interactive.cmd",
      "args": [], // 尾注释
    },
    "broken": { "type": "custom" },
  },
}"#,
        )
        .expect("write");
        let store = SettingsStore::new(dir.clone());
        // 本地已有同名的 dsh，导入不得覆盖它的 command。
        store
            .upsert("dsh-acp-interactive", AgentServer::Custom { path: "local.cmd".into(), args: vec![], env: BTreeMap::new(), extra: BTreeMap::new() })
            .expect("upsert");
        let report = store.import_zed(&zed).expect("import");
        assert_eq!(report.imported, vec!["codex-acp".to_string(), "cursor".to_string()]);
        assert_eq!(report.skipped, vec!["dsh-acp-interactive".to_string()]);
        assert_eq!(report.invalid, vec!["broken".to_string()]);
        let settings = store.load().expect("load");
        assert!(matches!(settings.agent_servers.get("dsh-acp-interactive"), Some(AgentServer::Custom { path, .. }) if path == "local.cmd"));
        // registry 型的额外字段（default_config_options）原样保留。
        let codex = serde_json::to_value(settings.agent_servers.get("codex-acp").expect("codex")).expect("json");
        assert_eq!(codex["default_config_options"]["mode"], "agent");
        // 再导一次：全部同名跳过，文件不重写。
        let before = std::fs::metadata(&store.path).expect("meta").modified().expect("mtime");
        let again = store.import_zed(&zed).expect("import");
        assert!(again.imported.is_empty());
        assert_eq!(again.skipped.len(), 3);
        assert_eq!(std::fs::metadata(&store.path).expect("meta").modified().expect("mtime"), before);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
