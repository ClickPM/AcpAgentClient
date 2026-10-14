#!/usr/bin/env bash
# macOS / Unix 验证门（R9，与 scripts/validate.ps1 逐项对齐）。
#   bash scripts/validate.sh           # 全部检查（静态门 + cargo + flutter）
#   bash scripts/validate.sh --quick   # 只跑静态门
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$HOME/flutter/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

QUICK=0
if [ "${1:-}" = "--quick" ] || [ "${1:-}" = "-Quick" ]; then
  QUICK=1
fi

PYTHON_BIN="$(command -v python3 || command -v python)"

echo "---- fetch-upstream --check (规则 4)"
bash "$ROOT/scripts/fetch-upstream.sh" --check
echo "PASS  fetch-upstream --check (规则 4)"

"$PYTHON_BIN" - "$ROOT" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
rust = root / "rust"
failures = []

def step(name, fn):
    print(f"---- {name}")
    try:
        msg = fn()
        if msg:
            print(msg)
        print(f"PASS  {name}")
    except Exception as e:
        print(f"FAIL  {name}: {e}")
        failures.append(name)

excluded_dirs = {"vendor", "build", "target", ".dart_tool", ".git", "cargokit", "node_modules"}

def source_files(base: pathlib.Path, exts):
    out = []
    for p in sorted(base.rglob("*")):
        if not p.is_file():
            continue
        if any(part in excluded_dirs for part in p.relative_to(root).parts):
            continue
        if p.suffix in exts:
            out.append(p)
    return out

def check_rust_sdk_pin():
    pins = json.loads((root / "pins/upstream.json").read_text(encoding="utf-8"))
    sdk = next(u["commit"] for u in pins["upstream"] if u["name"] == "rust-sdk")
    toml = (rust / "Cargo.toml").read_text(encoding="utf-8")
    if not re.search(r'rev\s*=\s*"' + re.escape(sdk) + r'"', toml):
        raise RuntimeError(f"rust/Cargo.toml does not pin rust-sdk rev {sdk}")
    if "unstable_protocol_v2" in toml:
        raise RuntimeError("unstable_protocol_v2 must not be enabled (规则 10)")

def check_unsafe():
    hits = []
    for f in source_files(rust, {".rs"}):
        if f.name == "frb_generated.rs":
            continue
        for idx, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if re.match(r"^\s*//", line) or "unsafe_code" in line:
                continue
            if re.search(r"\bunsafe\b", line):
                hits.append(f"{f}:{idx}: {line.strip()}")
    if hits:
        raise RuntimeError("unsafe found:\n" + "\n".join(hits))

def check_meta_keys():
    allowed = {
        "terminal_output", "terminal-auth", "parameterizedModelPicker",
        "claudeCode.parentToolUseId", "claudeCode.subagent", "claudeCode.toolName", "dsh_subagent",
        "terminal_info", "terminal_exit",
    }
    design = (root / "docs/design.md").read_text(encoding="utf-8")
    for k in allowed:
        if k not in design:
            raise RuntimeError(f"allowed key '{k}' is not mentioned in docs/design.md")
    keys_file = rust / "acp-core/src/meta_keys.rs"
    for m in re.finditer(r'pub const \w+: &str = "([^"]+)";', keys_file.read_text(encoding="utf-8")):
        k = m.group(1)
        if k == "terminal_id":
            continue
        if k not in allowed:
            raise RuntimeError(f"{keys_file} declares '{k}' which is not in docs/design.md § 4")
    bad = []
    for f in source_files(rust, {".rs"}):
        if f.name in {"meta_keys.rs", "frb_generated.rs"}:
            continue
        for idx, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if re.match(r"^\s*//", line):
                continue
            if re.search(r"\b_meta\b", line):
                cleaned = line.replace('"_meta"', "")
                if re.search(r'"[A-Za-z][\w.\-]*"', cleaned):
                    bad.append(f"{f}:{idx}: {line.strip()}")
    if bad:
        raise RuntimeError("_meta lines with literal keys:\n" + "\n".join(bad))

def check_notice():
    notice_path = root / "NOTICE"
    if not notice_path.exists():
        raise RuntimeError("NOTICE is missing")
    notice = notice_path.read_text(encoding="utf-8")
    m = re.search(r"Pinned at commit ([0-9a-f]{7,40})", notice)
    if not m:
        raise RuntimeError("NOTICE has no 'Pinned at commit' line")
    zed = m.group(1)
    files = source_files(rust, {".rs", ".dart"}) + source_files(root / "lib", {".rs", ".dart"})
    derived = []
    for f in files:
        text = f.read_text(encoding="utf-8")
        head = "\n".join(text.splitlines()[:5])
        mentions = ("zed-industries/zed" in text) or ("Derived from" in text)
        hm = re.search(r"Derived from zed-industries/zed (\S+) @ ([0-9a-f]{7,40})", head)
        if hm:
            if not zed.startswith(hm.group(2)):
                raise RuntimeError(f"{f}: derived-from commit {hm.group(2)} != NOTICE zed commit {zed}")
            derived.append(f.relative_to(root).as_posix())
        elif mentions:
            raise RuntimeError(f"{f} mentions Zed sources but lacks the 'Derived from zed-industries/zed <path> @ <commit>' header")
    missing = [d for d in derived if d not in notice]
    if missing:
        raise RuntimeError("derived files missing from NOTICE:\n" + "\n".join(missing))
    listed = [m.group(1) for m in re.finditer(r"(?m)^\s{2}(\S+)\s+<-\s+(\S+)\s*$", notice)]
    stale = []
    for p in listed:
        if not (root / p).exists():
            stale.append(f"{p} (listed in NOTICE, not on disk)")
        elif p.endswith((".rs", ".dart")) and p not in derived:
            stale.append(f"{p} (listed in NOTICE, but has no 'Derived from' header)")
    if stale:
        raise RuntimeError("NOTICE is stale:\n" + "\n".join(stale))
    return f"derived files: {len(derived)}; NOTICE entries: {len(listed)}"

def check_versions():
    pubspec = (root / "pubspec.yaml").read_text(encoding="utf-8")
    pm = re.search(r"(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", pubspec)
    if not pm:
        raise RuntimeError("pubspec.yaml has no version: X.Y.Z+N line")
    app_ver = pm.group(1)
    rust_toml = (rust / "Cargo.toml").read_text(encoding="utf-8")
    rm = re.search(r'(?ms)\[workspace\.package\].*?^version\s*=\s*"([^"]+)"', rust_toml)
    if not rm:
        raise RuntimeError("rust/Cargo.toml has no [workspace.package] version")
    if rm.group(1) != app_ver:
        raise RuntimeError(f"app version mismatch: pubspec.yaml {app_ver} vs rust/Cargo.toml {rm.group(1)}")
    return f"app {app_ver}"

def check_pubspec_whitelist():
    allowed = {
        "flutter", "flutter_rust_bridge", "xterm", "url_launcher", "file_selector", "flutter_svg",
        "markdown", "re_highlight", "flutter_math_fork", "mermaid_flutter", "mermaid_core", "audioplayers", "diffutil_dart",
        "flutter_test", "flutter_lints", "integration_test",
    }
    section = ""
    deps = []
    for line in (root / "pubspec.yaml").read_text(encoding="utf-8").splitlines():
        m_sec = re.match(r"^(dependencies|dev_dependencies):\s*$", line)
        if m_sec:
            section = m_sec.group(1)
            continue
        if re.match(r"^\S", line):
            section = ""
            continue
        if section:
            m_dep = re.match(r"^  ([A-Za-z_][\w]*):", line)
            if m_dep:
                deps.append(m_dep.group(1))
    bad = [d for d in deps if d not in allowed]
    if bad:
        raise RuntimeError("dependencies outside 规则 1 whitelist: " + ", ".join(bad))
    return "deps: " + ", ".join(deps)

def check_style_literals():
    patterns = [
        re.compile(p) for p in [
            r"Color\(0x", r"Color\.from(RGBO|ARGB)\(", r"\bColors\.\w", r"fontSize:\s*\d",
            r"FontWeight\.w\d", r"letterSpacing:\s*\d",
            r"EdgeInsets\.(all|symmetric|only|fromLTRB)\([^)]*(?<![\w.])\d",
            r"Radius\.circular\(\s*\d", r"BorderRadius\.circular\(\s*\d",
            r"SizedBox\((width|height):\s*\d", r"Duration\(milliseconds:", r"BoxShadow\(", r"blurRadius:\s*\d",
            r"(?<![\w.])(height|width|minHeight|minWidth|maxHeight|maxWidth):\s*\d",
            r"Border\.all\([^)]*width:\s*\d", r"strokeWidth:\s*\d",
            r"Radius\.elliptical\(", r"(?<![\w.])Offset\(",
        ]
    ]
    files = [
        f for f in source_files(root / "lib", {".dart"})
        if "lib/bridge/" not in f.relative_to(root).as_posix()
        and f.relative_to(root).as_posix() != "lib/theme/tokens.dart"
    ]
    hits = []
    for f in files:
        for idx, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if re.match(r"^\s*//", line):
                continue
            for pat in patterns:
                if pat.search(line):
                    hits.append(f"{f}:{idx}: {line.strip()}")
                    break
    if hits:
        raise RuntimeError("style literals outside tokens.dart:\n" + "\n".join(hits))
    return f"scanned {len(files)} dart files"

def check_ambient_clock():
    files = [
        f for f in source_files(root / "lib", {".dart"})
        if "lib/bridge/" not in f.relative_to(root).as_posix()
    ]
    hits = []
    for f in files:
        for idx, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if re.match(r"^\s*//", line):
                continue
            if ".repeat(" in line:
                hits.append(f"{f}:{idx}: {line.strip()}")
    if hits:
        raise RuntimeError("AnimationController.repeat() in lib/:\n" + "\n".join(hits))
    return f"scanned {len(files)} dart files"

def check_app_line_limits():
    limits = {"workbench_controller.dart": 450, "headless_run.dart": 1300, "workbench_screen.dart": 1000}
    default_limit = 900
    bad = []
    app_files = sorted((root / "lib/app").glob("*.dart"))
    for f in app_files:
        n = len(f.read_text(encoding="utf-8").splitlines())
        lim = limits.get(f.name, default_limit)
        if n > lim:
            bad.append(f"{f.name}: {n} > {lim}")
    if bad:
        raise RuntimeError("lib/app files over the line limit:\n" + "\n".join(bad))
    return f"lib/app files: {len(app_files)}"

def check_app_dep_direction():
    allowed = {
        "session_attach.dart": ["workspace_state.dart", "guarded.dart", "core_bridge.dart"],
        "shell_state.dart": ["files_state.dart", "local_terminals.dart", "guarded.dart", "core_bridge.dart"],
        "workspace_state.dart": ["files_state.dart", "guarded.dart", "core_bridge.dart"],
        "session_index.dart": ["core_bridge.dart"],
        "agents_state.dart": ["guarded.dart", "core_bridge.dart"],
        "auth_state.dart": ["guarded.dart", "core_bridge.dart"],
        "composer_state.dart": ["guarded.dart", "core_bridge.dart", "clipboard_image.dart"],
        "turn_controller.dart": ["session_controller.dart", "session_attach.dart", "composer_state.dart", "guarded.dart", "core_bridge.dart", "send_queue.dart"],
        "session_controller.dart": ["session_index.dart", "session_attach.dart", "agents_state.dart", "workspace_state.dart", "guarded.dart", "core_bridge.dart"],
    }
    bad = []
    for f in sorted((root / "lib/app").glob("*.dart")):
        imports = re.findall(r"(?m)^import '([^']+)';", f.read_text(encoding="utf-8"))
        local = [imp for imp in imports if not re.match(r"^(package:|dart:|\.\./)", imp)]
        if "workbench_controller.dart" in local and f.name not in {"app.dart", "workbench_screen.dart", "headless_run.dart"}:
            bad.append(f"{f.name} imports workbench_controller.dart")
        if f.name in allowed:
            for imp in local:
                if imp not in allowed[f.name]:
                    bad.append(f"{f.name} -> {imp} is not an allowed edge")
    if bad:
        raise RuntimeError("dependency direction violated:\n" + "\n".join(bad))
    return f"checked {len(allowed)} sub-objects"

step("rust-sdk pin in rust/Cargo.toml == pins/upstream.json (规则 4)", check_rust_sdk_pin)
step("unsafe 字面扫描 (规则 6)", check_unsafe)
step("_meta 键 ⊆ docs/design.md § 4 (规则 2)", check_meta_keys)
step("派生文件头注释与 NOTICE 一致 (规则 5)", check_notice)
step("版本门：应用两处一致 (R8)", check_versions)
step("pubspec.yaml 依赖 ⊆ 白名单 (规则 1)", check_pubspec_whitelist)
step("Assert-NoStyleLiteral (规则 3)", check_style_literals)
step("常驻动画走共用时钟 (iteration-14)", check_ambient_clock)
step("lib/app 行数门 (R7.5)", check_app_line_limits)
step("lib/app 依赖方向门 (R7.5)", check_app_dep_direction)

if failures:
    print("\nVALIDATE FAILED: " + "; ".join(failures))
    sys.exit(1)
PY

if [ "$QUICK" = 0 ]; then
  echo "---- cargo build --workspace"
  (cd "$ROOT/rust" && cargo build --workspace --locked)
  echo "PASS  cargo build --workspace"

  echo "---- cargo test --workspace"
  (cd "$ROOT/rust" && cargo test --workspace --locked)
  echo "PASS  cargo test --workspace"

  echo "---- cargo clippy -D warnings"
  (cd "$ROOT/rust" && cargo clippy --workspace --all-targets --locked -- -D warnings)
  echo "PASS  cargo clippy -D warnings"

  echo "---- cargo tree 无 gpui (规则 5)"
  TREE_OUT="$(cd "$ROOT/rust" && cargo tree --workspace --locked)"
  if echo "$TREE_OUT" | grep -Eq '\bgpui\b'; then
    echo "FAIL  cargo tree 无 gpui: gpui appears in the rust/ dependency tree" >&2
    exit 1
  fi
  echo "PASS  cargo tree 无 gpui (规则 5)"

  echo "---- flutter analyze"
  (cd "$ROOT" && flutter analyze --no-fatal-infos)
  echo "PASS  flutter analyze"

  echo "---- flutter test"
  (cd "$ROOT" && flutter test)
  echo "PASS  flutter test"
fi

echo ""
echo "VALIDATE OK"
