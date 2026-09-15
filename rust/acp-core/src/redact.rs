//! `acp/traffic` 与日志的脱敏（CLAUDE.md 规则 8；docs/design.md § 10）：
//! `Authorization`、`api_key`、`token` 类字段一律打成 `***`。判定按键名（大小写无关的子串），
//! 另覆盖 `{name, value}` 形式的 header 条目（`mcpServers[].headers`）与 stderr 里的 `Bearer <token>` / `KEY=value`。

use serde_json::Value;

const MASK: &str = "***";

/// 键名里出现这些子串（大小写无关）就算敏感：`authorization`、`api_key` / `apikey`、`token`、`secret`、`password`。
const SENSITIVE_KEY_PARTS: &[&str] = &["authorization", "api_key", "apikey", "token", "secret", "password"];

pub fn is_sensitive_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    SENSITIVE_KEY_PARTS.iter().any(|part| lower.contains(part))
}

/// 就地打码：敏感键的值整个换成 `***`（不论值是字符串还是对象），其余递归。
pub fn redact_value(value: &mut Value) {
    match value {
        Value::Object(map) => {
            let header_like = map.get("name").and_then(Value::as_str).is_some_and(is_sensitive_key) && map.contains_key("value");
            for (key, child) in map.iter_mut() {
                if is_sensitive_key(key) || (header_like && key == "value") {
                    *child = Value::String(MASK.to_string());
                } else {
                    redact_value(child);
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(redact_value),
        _ => {}
    }
}

/// 一行 JSON-RPC：能解析就按键打码后重新序列化；解析不了（stderr 之类）走文本规则。
pub fn redact_line(line: &str) -> String {
    match serde_json::from_str::<Value>(line) {
        Ok(mut v) if v.is_object() || v.is_array() => {
            redact_value(&mut v);
            v.to_string()
        }
        _ => redact_text(line),
    }
}

/// 文本规则：`Bearer xxx` 的 xxx、`KEY=value` 里敏感 KEY 的 value，按空白分词逐个处理。
pub fn redact_text(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut mask_next = false;
    let mut first = true;
    for token in line.split(' ') {
        if !first {
            out.push(' ');
        }
        first = false;
        if mask_next {
            out.push_str(MASK);
            mask_next = false;
            continue;
        }
        if token.eq_ignore_ascii_case("bearer") {
            out.push_str(token);
            mask_next = true;
            continue;
        }
        if let Some((key, _)) = token.split_once('=')
            && is_sensitive_key(key)
        {
            out.push_str(key);
            out.push('=');
            out.push_str(MASK);
            continue;
        }
        out.push_str(token);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn masks_sensitive_keys_recursively() {
        let mut v = json!({
            "method": "session/new",
            "params": {
                "cwd": "D:/x",
                "mcpServers": [{
                    "type": "http",
                    "name": "bi",
                    "headers": [{"name": "Authorization", "value": "Bearer FAKE"}, {"name": "X-Trace", "value": "keep"}]
                }],
                "env": {"DEEPSEEK_API_KEY": "sk-1", "PATH": "C:/bin"},
                "token": {"nested": "gone"},
                "access_token": "a",
                "apiKey": "b",
                "client_secret": "c",
                "password": "d"
            }
        });
        redact_value(&mut v);
        let p = &v["params"];
        assert_eq!(p["cwd"], "D:/x");
        assert_eq!(p["mcpServers"][0]["headers"][0]["value"], "***");
        assert_eq!(p["mcpServers"][0]["headers"][0]["name"], "Authorization");
        assert_eq!(p["mcpServers"][0]["headers"][1]["value"], "keep");
        assert_eq!(p["env"]["DEEPSEEK_API_KEY"], "***");
        assert_eq!(p["env"]["PATH"], "C:/bin");
        assert_eq!(p["token"], "***");
        assert_eq!(p["access_token"], "***");
        assert_eq!(p["apiKey"], "***");
        assert_eq!(p["client_secret"], "***");
        assert_eq!(p["password"], "***");
    }

    #[test]
    fn redacts_json_lines_and_text_lines() {
        let line = r#"{"jsonrpc":"2.0","id":1,"method":"x","params":{"api_key":"sk","keep":1}}"#;
        let out = redact_line(line);
        assert!(out.contains(r#""api_key":"***""#), "{out}");
        assert!(out.contains(r#""keep":1"#));
        assert!(!out.contains("sk\""));

        assert_eq!(redact_text("Authorization: Bearer abc.def rest"), "Authorization: Bearer *** rest");
        assert_eq!(redact_text("DEEPSEEK_API_KEY=sk-live PATH=/bin"), "DEEPSEEK_API_KEY=*** PATH=/bin");
        assert_eq!(redact_line("[dsh] turn finished in 6.2s"), "[dsh] turn finished in 6.2s");
        // 不是对象 / 数组的 JSON（裸字符串、数字）按文本规则走，不改。
        assert_eq!(redact_line("42"), "42");
    }
}
