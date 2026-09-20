// Derived from zed-industries/zed crates/eval_cli/build.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)
// （转写：路径从 `../zed/Cargo.toml`（同 workspace 的兄弟 crate）改成 vendor 里的钉版本副本；
// 读不到时不再 panic，退回 "0.0.0" —— 它只用于 User-Agent 与遥测字符串，缺了不该挡住构建。
// R8 另加 ZED_PINNED_COMMIT：`--version` 要能说清自己包的是哪个 zed。）

const ZED_MANIFEST: &str = "../../vendor/upstream/zed/crates/zed/Cargo.toml";
const PINS: &str = "../../pins/upstream.json";

fn main() {
    println!("cargo:rerun-if-changed={ZED_MANIFEST}");
    println!("cargo:rerun-if-changed={PINS}");
    let version = std::fs::read_to_string(ZED_MANIFEST)
        .ok()
        .and_then(|manifest| {
            manifest
                .lines()
                .find(|line| line.starts_with("version = "))
                .and_then(|line| line.split('=').nth(1))
                .map(|value| value.trim().trim_matches('"').to_owned())
        })
        .unwrap_or_else(|| "0.0.0".to_owned());
    println!("cargo:rustc-env=ZED_PKG_VERSION={version}");

    // pins/upstream.json 里 zed 那条的 commit（CLAUDE.md 规则 4：pins 是上游唯一事实来源）。
    // 手工扫而不引 serde：build 依赖会进每一次冷编译，而这里只要一个字符串。读不到退回 "unknown"。
    let commit = std::fs::read_to_string(PINS)
        .ok()
        .and_then(|pins| pinned_commit(&pins, "zed"))
        .unwrap_or_else(|| "unknown".to_owned());
    println!("cargo:rustc-env=ZED_PINNED_COMMIT={commit}");
}

/// `"name": "<name>"` 之后的第一个 `"commit": "<value>"`。
/// 认的是 pins 文件当前的写法（`"name": "zed",` 带一个空格）；排版真变了就退回 "unknown"，
/// 而 scripts/validate.ps1 的版本门照样会拦住版本对不上的情况。
fn pinned_commit(pins: &str, name: &str) -> Option<String> {
    let needle = format!("\"name\": \"{name}\"");
    let rest = &pins[pins.find(&needle)? + needle.len()..];
    let key = "\"commit\": \"";
    let value = &rest[rest.find(key)? + key.len()..];
    let end = value.find('"')?;
    Some(value[..end].to_owned())
}
