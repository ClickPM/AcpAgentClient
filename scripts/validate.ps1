# 验证门（CLAUDE.md「本地开发」；R0 落地）。全绿才允许发起审查。
#   powershell -File scripts/validate.ps1            # 全部
#   powershell -File scripts/validate.ps1 -Quick     # 跳过 cargo / flutter 的编译与测试，只跑静态检查
# 检查项：cargo build / test / clippy -D warnings、unsafe 字面扫描（规则 6）、cargo tree 无 gpui（规则 5）、
# flutter analyze / test、pubspec 依赖 ⊆ 白名单（规则 1）、Assert-NoStyleLiteral（规则 3）、
# rust/ 的 _meta 键 ⊆ docs/design.md § 4（规则 2）、Zed 派生文件头注释（规则 5）、fetch-upstream -Check（规则 4）。
# R7.5 起另有两道门：lib/app 行数门（组合根 ≤ 450、其余 ≤ 900）与 lib/app 依赖方向门（任务卡附录 B 的边）。
param(
    [switch]$Quick,
    [string]$CargoTargetDir = "D:\cargo-target\AcpAgentClient"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]
function Step($name, [scriptblock]$body) {
    Write-Host ("---- " + $name)
    try {
        & $body
        Write-Host ("PASS  " + $name)
    } catch {
        Write-Host ("FAIL  " + $name + ": " + $_.Exception.Message)
        $failures.Add($name)
    }
}
function Invoke-Checked([string]$title, [string]$exe, [string[]]$argv, [string]$cwd) {
    Push-Location $cwd
    try {
        & $exe @argv
        if ($LASTEXITCODE -ne 0) { throw "$title exited $LASTEXITCODE" }
    } finally { Pop-Location }
}

# 源码文件枚举：排除 vendor / build / 生成物。
function Get-SourceFiles([string]$dir, [string[]]$patterns) {
    Get-ChildItem -Path $dir -Recurse -File -Include $patterns |
        Where-Object { $_.FullName -notmatch '[\\/](vendor|build|target|\.dart_tool|\.git|cargokit|node_modules)[\\/]' }
}

Push-Location $root
try {
    New-Item -ItemType Directory -Force $CargoTargetDir | Out-Null
    $env:CARGO_TARGET_DIR = $CargoTargetDir
    $rust = Join-Path $root "rust"
    # sidecar/ 是另一个 cargo workspace（R7），但规则 2 / 6 对它一样生效，下面几步一并扫。
    $sidecar = Join-Path $root "sidecar"
    $rustRoots = @($rust)
    if (Test-Path $sidecar) { $rustRoots += $sidecar }

    Step "fetch-upstream -Check (规则 4)" {
        & powershell -NoProfile -File (Join-Path $root "scripts\fetch-upstream.ps1") -Check
        if ($LASTEXITCODE -ne 0) { throw "pins drifted or missing" }
    }

    Step "rust-sdk pin in rust/Cargo.toml == pins/upstream.json (规则 4)" {
        $pins = Get-Content (Join-Path $root "pins/upstream.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $sdk = ($pins.upstream | Where-Object { $_.name -eq "rust-sdk" }).commit
        $toml = Get-Content (Join-Path $rust "Cargo.toml") -Raw -Encoding UTF8
        if ($toml -notmatch ('rev\s*=\s*"' + [regex]::Escape($sdk) + '"')) { throw "rust/Cargo.toml does not pin rust-sdk rev $sdk" }
        if ($toml -match 'unstable_protocol_v2') { throw "unstable_protocol_v2 must not be enabled (规则 10)" }
    }

    Step "unsafe 字面扫描 (规则 6)" {
        $hits = ($rustRoots | ForEach-Object { Get-SourceFiles $_ @("*.rs") }) |
            Where-Object { $_.Name -ne "frb_generated.rs" } |
            Select-String -Pattern '\bunsafe\b' |
            Where-Object { $_.Line -notmatch '^\s*//' -and $_.Line -notmatch 'unsafe_code' }
        if ($hits) { throw ("unsafe found:`n" + (($hits | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }) -join "`n")) }
    }

    Step "_meta 键 ⊆ docs/design.md § 4 (规则 2)" {
        # 允许的键（docs/design.md § 4 出站清单 + 入站识别键）。改清单先改文档再改这里。
        $allowed = @("terminal_output", "terminal-auth", "parameterizedModelPicker",
                     "claudeCode.parentToolUseId", "claudeCode.subagent", "claudeCode.toolName", "dsh_subagent",
                     "terminal_info", "terminal_exit")
        $design = Get-Content (Join-Path $root "docs/design.md") -Raw -Encoding UTF8
        foreach ($k in $allowed) {
            if ($design -notmatch [regex]::Escape($k)) { throw "allowed key '$k' is not mentioned in docs/design.md" }
        }
        # 两份 meta_keys.rs：核心一份，sidecar 一份（独立 workspace，依赖不到 acp-core）。
        $keyFiles = @(Join-Path $rust "acp-core\src\meta_keys.rs")
        $sidecarKeys = Join-Path $sidecar "zed-agent-acp\src\meta_keys.rs"
        if (Test-Path $sidecarKeys) { $keyFiles += $sidecarKeys }
        foreach ($keysFile in $keyFiles) {
            $consts = Select-String -Path $keysFile -Pattern 'pub const \w+: &str = "([^"]+)";' | ForEach-Object { $_.Matches[0].Groups[1].Value }
            foreach ($k in $consts) {
                # terminal_id 是那三个键共有的**字段名**，不是 _meta 的顶层键，不进 § 4 清单。
                if ($k -eq "terminal_id") { continue }
                if ($allowed -notcontains $k) { throw "$keysFile declares '$k' which is not in docs/design.md § 4" }
            }
        }
        # 其他文件里带 _meta 的行不得携带字符串字面量键：键只能来自 meta_keys 常量。
        # 按整词认 _meta（前后都不是标识符字符）：symlink_metadata / terminal_exit_meta 这类标识符里的子串不算。
        $bad = ($rustRoots | ForEach-Object { Get-SourceFiles $_ @("*.rs") }) |
            Where-Object { $_.Name -notin @("meta_keys.rs", "frb_generated.rs") } |
            Select-String -Pattern '\b_meta\b' |
            Where-Object { $_.Line -notmatch '^\s*//' -and (($_.Line -replace '"_meta"', '') -match '"[A-Za-z][\w.\-]*"') }
        if ($bad) { throw ("_meta lines with literal keys (use acp_core::meta_keys):`n" + (($bad | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }) -join "`n")) }
    }

    Step "Zed 派生文件头注释与 NOTICE 一致 (规则 5)" {
        # 头注释扫描（规则 5）+ R8 验收 4：扫出来的每个派生文件都要在 NOTICE 第 1 节里列着，
        # NOTICE 里列的源码文件也都要真的存在且带头注释 —— 两边任一方向漏掉都算过期。
        $pins = Get-Content (Join-Path $root "pins/upstream.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $zed = ($pins.upstream | Where-Object { $_.name -eq "zed" }).commit
        $files = @()
        foreach ($d in @("rust", "lib", "sidecar")) {
            $p = Join-Path $root $d
            if (Test-Path $p) { $files += Get-SourceFiles $p @("*.rs", "*.dart") }
        }
        $derived = @()
        foreach ($f in $files) {
            $head = (Get-Content $f.FullName -TotalCount 5 -Encoding UTF8) -join "`n"
            $body = Get-Content $f.FullName -Raw -Encoding UTF8
            $mentions = $body -match 'zed-industries/zed' -or $body -match 'Derived from'
            if ($head -match 'Derived from zed-industries/zed (\S+) @ ([0-9a-f]{7,40})') {
                if ($zed -notlike ($Matches[2] + "*")) { throw "$($f.FullName): derived-from commit $($Matches[2]) != pinned zed $zed" }
                $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
                $derived += $rel
            } elseif ($mentions) {
                throw "$($f.FullName) mentions Zed sources but lacks the 'Derived from zed-industries/zed <path> @ <commit>' header"
            }
        }
        $noticePath = Join-Path $root "NOTICE"
        if (-not (Test-Path $noticePath)) { throw "NOTICE is missing (GPL redistribution: 见 README「许可证」)" }
        $notice = Get-Content $noticePath -Raw -Encoding UTF8
        if ($notice -notmatch [regex]::Escape($zed)) { throw "NOTICE does not name the pinned zed commit $zed" }
        $missing = $derived | Where-Object { $notice -notmatch [regex]::Escape($_) }
        if ($missing) { throw ("derived files missing from NOTICE:`n" + ($missing -join "`n")) }
        # NOTICE 第 1 节的「<本仓库路径> <- <zed 路径>」行反向核对。
        $listed = [regex]::Matches($notice, '(?m)^\s{2}(\S+)\s+<-\s+(\S+)\s*$') | ForEach-Object { $_.Groups[1].Value }
        $stale = @()
        foreach ($p in $listed) {
            if (-not (Test-Path (Join-Path $root $p))) { $stale += "$p (listed in NOTICE, not on disk)" }
            elseif ($p -match '\.(rs|dart)$' -and $derived -notcontains $p) { $stale += "$p (listed in NOTICE, but has no 'Derived from' header)" }
        }
        if ($stale) { throw ("NOTICE is stale:`n" + ($stale -join "`n")) }
        Write-Host ("derived files: " + $derived.Count + "; NOTICE entries: " + $listed.Count)
    }

    Step "版本门：应用两处一致、sidecar 跟 zed 钉版本 (R8)" {
        # 发版要改的**应用**版本只有两处：pubspec.yaml 与 rust/Cargo.toml 的 [workspace.package]。
        # sidecar 不在其列（所有者裁定 2026-09-20）：它的版本跟 pins 里的 zed 走，改一次要全量重链约 15 分钟，
        # 而发应用版本根本不动 sidecar 的源码。三方（pins / vendor 里的 zed manifest / sidecar manifest）必须一致。
        $pubspec = Get-Content (Join-Path $root "pubspec.yaml") -Raw -Encoding UTF8
        if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') { throw 'pubspec.yaml has no version: X.Y.Z+N line' }
        $appVersion = $Matches[1]
        $rustToml = Get-Content (Join-Path $root "rust/Cargo.toml") -Raw -Encoding UTF8
        if ($rustToml -notmatch '(?ms)\[workspace\.package\].*?^version\s*=\s*"([^"]+)"') { throw "rust/Cargo.toml has no [workspace.package] version" }
        if ($Matches[1] -ne $appVersion) { throw "app version mismatch: pubspec.yaml $appVersion vs rust/Cargo.toml $($Matches[1])" }

        $pins = Get-Content (Join-Path $root "pins/upstream.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $zedPin = $pins.upstream | Where-Object { $_.name -eq "zed" }
        if (-not $zedPin.version) { throw 'pins/upstream.json: the zed entry has no version field' }
        $sidecarVersion = "(no sidecar)"
        $sidecarToml = Join-Path $root "sidecar/zed-agent-acp/Cargo.toml"
        if (Test-Path $sidecarToml) {
            $sidecar = Get-Content $sidecarToml -Raw -Encoding UTF8
            if ($sidecar -notmatch '(?ms)^\[package\].*?^version\s*=\s*"([^"]+)"') { throw "sidecar Cargo.toml has no [package] version" }
            $sidecarVersion = $Matches[1]
            # 只核对「== pins 的 zed 版本」：那一条成立时 sidecar 就不可能是跟着应用抬上来的。
            # 不再另判「!= 应用版本」——应用哪天正好升到和 zed 钉版本同号（1.21.0）时，那一判会与这一条互相死锁。
            if ($sidecarVersion -ne $zedPin.version) { throw "sidecar version $sidecarVersion != pinned zed version $($zedPin.version) (改 zed 钉版本时一起改；发应用版本时别动它)" }
            $zedManifest = Join-Path $root "vendor/upstream/zed/crates/zed/Cargo.toml"
            if (Test-Path $zedManifest) {
                $zedToml = Get-Content $zedManifest -Raw -Encoding UTF8
                if ($zedToml -notmatch '(?m)^version\s*=\s*"([^"]+)"') { throw "vendor zed manifest has no version" }
                if ($Matches[1] -ne $zedPin.version) { throw "pins zed version $($zedPin.version) != vendor/upstream/zed $($Matches[1])" }
            }
        }
        Write-Host ("app " + $appVersion + "; sidecar " + $sidecarVersion + " (zed pin)")
    }

    Step "pubspec.yaml 依赖 ⊆ 白名单 (规则 1)" {
        # CLAUDE.md 规则 1 Dart 侧通用库清单（R1.5 裁定 2026-09-15 加入 markdown / re_highlight / flutter_math_fork / mermaid_flutter + mermaid_core / audioplayers / diffutil_dart）。
        # 只核对直接依赖，传递依赖不算引入；flutter_lints / flutter_test 是工具。
        $allowed = @("flutter", "flutter_rust_bridge", "xterm", "url_launcher", "file_selector", "flutter_svg",
                     "markdown", "re_highlight", "flutter_math_fork", "mermaid_flutter", "mermaid_core", "audioplayers", "diffutil_dart",
                     "flutter_test", "flutter_lints", "integration_test")
        $lines = Get-Content (Join-Path $root "pubspec.yaml") -Encoding UTF8
        $section = ""
        $deps = @()
        foreach ($l in $lines) {
            if ($l -match '^(dependencies|dev_dependencies):\s*$') { $section = $Matches[1]; continue }
            if ($l -match '^\S') { $section = ""; continue }
            if ($section -and $l -match '^  ([A-Za-z_][\w]*):') { $deps += $Matches[1] }
        }
        $bad = $deps | Where-Object { $allowed -notcontains $_ }
        if ($bad) { throw ("dependencies outside 规则 1 whitelist: " + ($bad -join ", ")) }
        Write-Host ("deps: " + ($deps -join ", "))
    }

    Step "Assert-NoStyleLiteral (规则 3)" {
        # 扫 lib/ 除 theme/tokens.dart 与 bridge/ 之外的颜色 / 字号 / 字重 / 间距 / 圆角 / 阴影 / 动效时长（毫秒）字面量。
        # 秒级 Duration 是超时逻辑不是样式，不在此列。
        # 图标路径几何（Radius.elliptical / Offset）R2 起纳入：画板图标全部是 lib/ui/transcript/icons.dart 的内联 SVG（flutter_svg）。
        $patterns = @(
            'Color\(0x', 'Color\.from(RGBO|ARGB)\(', '\bColors\.\w', 'fontSize:\s*\d', 'FontWeight\.w\d', 'letterSpacing:\s*\d',
            'EdgeInsets\.(all|symmetric|only|fromLTRB)\([^)]*(?<![\w.])\d', 'Radius\.circular\(\s*\d', 'BorderRadius\.circular\(\s*\d',
            'SizedBox\((width|height):\s*\d', 'Duration\(milliseconds:', 'BoxShadow\(', 'blurRadius:\s*\d',
            '(?<![\w.])(height|width|minHeight|minWidth|maxHeight|maxWidth):\s*\d', 'Border\.all\([^)]*width:\s*\d', 'strokeWidth:\s*\d',
            'Radius\.elliptical\(', '(?<![\w.])Offset\('
        )
        $files = Get-SourceFiles (Join-Path $root "lib") @("*.dart") |
            Where-Object { $_.FullName -notmatch '[\\/]lib[\\/]bridge[\\/]' -and $_.FullName -notmatch '[\\/]lib[\\/]theme[\\/]tokens\.dart$' }
        $hits = @()
        foreach ($f in $files) {
            $n = 0
            foreach ($line in (Get-Content $f.FullName -Encoding UTF8)) {
                $n++
                if ($line -match '^\s*//') { continue }
                foreach ($p in $patterns) {
                    if ($line -match $p) { $hits += "$($f.FullName):${n}: $($line.Trim())"; break }
                }
            }
        }
        if ($hits) { throw ("style literals outside tokens.dart:`n" + ($hits -join "`n")) }
        Write-Host ("scanned " + $files.Count + " dart files")
    }

    Step "lib/app 行数门 (R7.5)" {
        # R7.5 组合根拆分（rounds/round-7.5/round-7.5.md 验收 5）：组合根 ≤ 450 行，lib/app 下任何文件 ≤ 900 行，
        # 防止组合根再长回上帝对象。改阈值先改任务卡再改这里。
        # 行数按原始行计（与 wc -l 同口径，空行也算）。两处显式放宽，都是本轮只改了引用路径的既有文件：
        # headless_run.dart 是 R3 / R5 / R6 三个无头实跑模式的驱动（基线 1186 行），不是产品代码（入口 lib/main_headless.dart）；
        # workbench_screen.dart 在画板 43 之后就是 946 行（任务卡「2026-09-20 复核」记为观察项）。
        # 不拆、接受放宽（所有者裁定 2026-09-23，原条目在 rounds/BACKLOG-CLOSED.md）；再长就得回来动这两个数字或拆。
        $limits = @{ "workbench_controller.dart" = 450; "headless_run.dart" = 1300; "workbench_screen.dart" = 1000 }
        $default = 900
        $bad = @()
        foreach ($f in (Get-ChildItem (Join-Path $root "lib\app") -File -Filter *.dart)) {
            $n = @(Get-Content $f.FullName -Encoding UTF8).Count
            $limit = if ($limits.ContainsKey($f.Name)) { $limits[$f.Name] } else { $default }
            if ($n -gt $limit) { $bad += "$($f.Name): $n > $limit" }
        }
        if ($bad) { throw ("lib/app files over the line limit:`n" + ($bad -join "`n")) }
        Write-Host ("lib/app files: " + (Get-ChildItem (Join-Path $root "lib\app") -File -Filter *.dart).Count)
    }

    Step "lib/app 依赖方向门 (R7.5)" {
        # R7.5 任务卡附录 B：只有 app.dart / workbench_screen.dart / headless_run.dart 可以 import 组合根；
        # 八个子对象之间只允许下面列出的边（谁 → 谁），反向一律走组合根接的回调。
        # session_attach.dart（iteration-07）是会话控制器混入的挂载那一段（从 session_controller.dart 拆出，行数门），
        # 边是会话控制器自己那几条的子集；一轮对话只用它的四态枚举分流。
        $allowed = @{
            "session_attach.dart"    = @("workspace_state.dart", "guarded.dart", "core_bridge.dart")
            "shell_state.dart"       = @("files_state.dart", "local_terminals.dart", "guarded.dart", "core_bridge.dart")
            "workspace_state.dart"   = @("files_state.dart", "guarded.dart", "core_bridge.dart")
            "session_index.dart"     = @("core_bridge.dart")
            "agents_state.dart"      = @("guarded.dart", "core_bridge.dart")
            "auth_state.dart"        = @("guarded.dart", "core_bridge.dart")
            "composer_state.dart"    = @("guarded.dart", "core_bridge.dart", "clipboard_image.dart")
            "turn_controller.dart"   = @("session_controller.dart", "session_attach.dart", "composer_state.dart", "guarded.dart", "core_bridge.dart")
            "session_controller.dart" = @("session_index.dart", "session_attach.dart", "agents_state.dart", "workspace_state.dart", "guarded.dart", "core_bridge.dart")
        }
        $appDir = Join-Path $root "lib\app"
        $bad = @()
        foreach ($f in (Get-ChildItem $appDir -File -Filter *.dart)) {
            $imports = Select-String -Path $f.FullName -Pattern "^import '([^']+)';" | ForEach-Object { $_.Matches[0].Groups[1].Value }
            $local = $imports | Where-Object { $_ -notmatch '^(package:|dart:|\.\./)' }
            if ($local -contains "workbench_controller.dart" -and $f.Name -notin @("app.dart", "workbench_screen.dart", "headless_run.dart")) {
                $bad += "$($f.Name) imports workbench_controller.dart"
            }
            if ($allowed.ContainsKey($f.Name)) {
                foreach ($imp in $local) {
                    if ($allowed[$f.Name] -notcontains $imp) { $bad += "$($f.Name) -> $imp is not an allowed edge (task card appendix B)" }
                }
            }
        }
        if ($bad) { throw ("dependency direction violated:`n" + ($bad -join "`n")) }
        Write-Host ("checked " + $allowed.Count + " sub-objects")
    }

    if (-not $Quick) {
        Step "cargo build --workspace" { Invoke-Checked "cargo build" "cargo" @("build", "--workspace", "--locked") $rust }
        Step "cargo test --workspace" { Invoke-Checked "cargo test" "cargo" @("test", "--workspace", "--locked") $rust }
        Step "cargo clippy -D warnings" { Invoke-Checked "cargo clippy" "cargo" @("clippy", "--workspace", "--all-targets", "--locked", "--", "-D", "warnings") $rust }
        Step "cargo tree 无 gpui (规则 5)" {
            Push-Location $rust
            try {
                $tree = & cargo tree --workspace --locked 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) { throw "cargo tree failed" }
                if ($tree -match '(?m)^[^\n]*\bgpui\b') { throw "gpui appears in the rust/ dependency tree" }
            } finally { Pop-Location }
        }
        Step "flutter analyze" { Invoke-Checked "flutter analyze" "flutter" @("analyze", "--no-fatal-infos") $root }
        Step "flutter test" { Invoke-Checked "flutter test" "flutter" @("test") $root }
    }
} finally {
    Pop-Location
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host ("VALIDATE FAILED: " + ($failures -join "; "))
    exit 1
}
Write-Host "VALIDATE OK"
exit 0
