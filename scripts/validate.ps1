# 验证门（CLAUDE.md「本地开发」；R0 落地）。全绿才允许发起审查。
#   powershell -File scripts/validate.ps1            # 全部
#   powershell -File scripts/validate.ps1 -Quick     # 跳过 cargo / flutter 的编译与测试，只跑静态检查
# 检查项：cargo build / test / clippy -D warnings、unsafe 字面扫描（规则 6）、cargo tree 无 gpui（规则 5）、
# flutter analyze / test、pubspec 依赖 ⊆ 白名单（规则 1）、Assert-NoStyleLiteral（规则 3）、
# rust/ 的 _meta 键 ⊆ docs/design.md § 4（规则 2）、Zed 派生文件头注释（规则 5）、fetch-upstream -Check（规则 4）。
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
        $hits = Get-SourceFiles $rust @("*.rs") |
            Where-Object { $_.Name -ne "frb_generated.rs" } |
            Select-String -Pattern '\bunsafe\b' |
            Where-Object { $_.Line -notmatch '^\s*//' -and $_.Line -notmatch 'unsafe_code' }
        if ($hits) { throw ("unsafe found:`n" + (($hits | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }) -join "`n")) }
    }

    Step "_meta 键 ⊆ docs/design.md § 4 (规则 2)" {
        # 允许的键（docs/design.md § 4 出站清单 + 入站识别键）。改清单先改文档再改这里。
        $allowed = @("terminal_output", "terminal-auth", "parameterizedModelPicker",
                     "claudeCode.parentToolUseId", "claudeCode.subagent", "claudeCode.toolName", "dsh_subagent")
        $design = Get-Content (Join-Path $root "docs/design.md") -Raw -Encoding UTF8
        foreach ($k in $allowed) {
            if ($design -notmatch [regex]::Escape($k)) { throw "allowed key '$k' is not mentioned in docs/design.md" }
        }
        $keysFile = Join-Path $rust "acp-core\src\meta_keys.rs"
        $consts = Select-String -Path $keysFile -Pattern 'pub const \w+: &str = "([^"]+)";' | ForEach-Object { $_.Matches[0].Groups[1].Value }
        foreach ($k in $consts) {
            if ($allowed -notcontains $k) { throw "meta_keys.rs declares '$k' which is not in docs/design.md § 4" }
        }
        # 其他文件里带 _meta 的行不得携带字符串字面量键：键只能来自 meta_keys 常量。
        $bad = Get-SourceFiles $rust @("*.rs") |
            Where-Object { $_.Name -notin @("meta_keys.rs", "frb_generated.rs") } |
            Select-String -Pattern '_meta' |
            Where-Object { $_.Line -notmatch '^\s*//' -and (($_.Line -replace '"_meta"', '') -match '"[A-Za-z][\w.\-]*"') }
        if ($bad) { throw ("_meta lines with literal keys (use acp_core::meta_keys):`n" + (($bad | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }) -join "`n")) }
    }

    Step "Zed 派生文件头注释 (规则 5)" {
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
                $derived += "$($f.FullName) <- $($Matches[1])"
            } elseif ($mentions) {
                throw "$($f.FullName) mentions Zed sources but lacks the 'Derived from zed-industries/zed <path> @ <commit>' header"
            }
        }
        Write-Host ("derived files: " + $derived.Count)
    }

    Step "pubspec.yaml 依赖 ⊆ 白名单 (规则 1)" {
        # CLAUDE.md 规则 1 Dart 侧通用库清单；diff 库与 Markdown 库在 R1.5 裁定后加入。flutter_lints / flutter_test 是工具。
        $allowed = @("flutter", "flutter_rust_bridge", "xterm", "url_launcher", "file_selector", "flutter_svg",
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
        # 图标路径几何（Radius.elliptical / Offset）暂不扫，R2 画板图标改用 flutter_svg 后纳入（rounds/BACKLOG.md）。
        $patterns = @(
            'Color\(0x', 'Color\.from(RGBO|ARGB)\(', '\bColors\.\w', 'fontSize:\s*\d', 'FontWeight\.w\d', 'letterSpacing:\s*\d',
            'EdgeInsets\.(all|symmetric|only|fromLTRB)\([^)]*(?<![\w.])\d', 'Radius\.circular\(\s*\d', 'BorderRadius\.circular\(\s*\d',
            'SizedBox\((width|height):\s*\d', 'Duration\(milliseconds:', 'BoxShadow\(', 'blurRadius:\s*\d',
            '(?<![\w.])(height|width|minHeight|minWidth|maxHeight|maxWidth):\s*\d', 'Border\.all\([^)]*width:\s*\d', 'strokeWidth:\s*\d'
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
