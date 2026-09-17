// Derived from zed-industries/zed crates/eval_cli/build.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)
// （转写：路径从 `../zed/Cargo.toml`（同 workspace 的兄弟 crate）改成 vendor 里的钉版本副本；
// 读不到时不再 panic，退回 "0.0.0" —— 它只用于 User-Agent 与遥测字符串，缺了不该挡住构建。）

const ZED_MANIFEST: &str = "../../vendor/upstream/zed/crates/zed/Cargo.toml";

fn main() {
    println!("cargo:rerun-if-changed={ZED_MANIFEST}");
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
}
