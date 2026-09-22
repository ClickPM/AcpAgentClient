# zed-agent-acp sidecar 的构建脚本（R7）。
#   powershell -File scripts/build-sidecar.ps1              # release
#   powershell -File scripts/build-sidecar.ps1 -Debug       # debug
#   powershell -File scripts/build-sidecar.ps1 -Check       # 只 cargo check（改代码后最快的回路）
#   powershell -File scripts/build-sidecar.ps1 -Clippy      # clippy -D warnings（validate.ps1 不跑 sidecar，太慢）
#   powershell -File scripts/build-sidecar.ps1 -Selftest    # 构建后跑一次 --selftest 无头自检
#
# 为什么不能直接 `cargo build --manifest-path sidecar/zed-agent-acp/Cargo.toml`：
#   1. sidecar 的 `.cargo/config.toml` 只在**工作目录位于它之内**时被 cargo 读到，而那里面的
#      `windows_slim_errors` / `+crt-static` 是 zed crate 编译的前提（见该文件注释）；
#   2. wasmtime（extension host 的依赖）的 build.rs 要 `cmake`，本机 cmake 只在 VS 2022 的
#      BuildTools 里、不在 PATH（R7 实测：不加就 `failed to spawn cmake: program not found`）；
#   3. CARGO_TARGET_DIR 要和主程序分开 —— 两边 rustflags 与 profile 都不同，共用会互相使缓存失效。
param(
    [switch]$Debug,
    [switch]$Check,
    [switch]$Clippy,
    [switch]$Selftest,
    [string]$CargoTargetDir = "D:\cargo-target\AcpAgentClient-sidecar"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$sidecar = Join-Path $root "sidecar\zed-agent-acp"
if (-not (Test-Path (Join-Path $sidecar "Cargo.toml"))) { throw "sidecar not found at $sidecar" }
if (-not (Test-Path (Join-Path $root "vendor\upstream\zed\crates\agent\Cargo.toml"))) {
    throw "vendor/upstream/zed 没填充：先跑 scripts/fetch-upstream.ps1（CLAUDE.md 规则 4）"
}

# cmake：优先 PATH 上的；没有就在 VS 2022 的几个安装位找一次。
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    $candidates = @(
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin",
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin",
        "C:\Program Files\CMake\bin"
    )
    $found = $candidates | Where-Object { Test-Path (Join-Path $_ "cmake.exe") } | Select-Object -First 1
    if (-not $found) { throw "找不到 cmake.exe（wasmtime 的 build.rs 需要它）；装 VS 2022 的「使用 C++ 的桌面开发」或独立 CMake" }
    $env:Path = "$found;$env:Path"
    Write-Host "== cmake: $found"
}

New-Item -ItemType Directory -Force $CargoTargetDir | Out-Null
$env:CARGO_TARGET_DIR = $CargoTargetDir

$profileArgs = @()
$profileDir = "debug"
if (-not $Debug) { $profileArgs = @("--release"); $profileDir = "release" }

Push-Location $sidecar
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($Clippy) {
        Write-Host "== cargo clippy --all-targets -- -D warnings"
        & cargo clippy --all-targets @profileArgs -- -D warnings
    } elseif ($Check) {
        Write-Host "== cargo check $profileArgs"
        & cargo check @profileArgs
    } else {
        Write-Host "== cargo build $profileArgs  (CARGO_TARGET_DIR=$CargoTargetDir)"
        & cargo build @profileArgs
    }
    if ($LASTEXITCODE -ne 0) { throw "cargo failed ($LASTEXITCODE)" }
    Write-Host ("== done in {0:0.0} min" -f $sw.Elapsed.TotalMinutes)
} finally { Pop-Location }

if ($Check -or $Clippy) { return }

$exe = Join-Path $CargoTargetDir "$profileDir\zed-agent-acp.exe"
if (-not (Test-Path $exe)) { throw "没产出 $exe" }
$size = [math]::Round((Get-Item $exe).Length / 1MB, 1)
Write-Host "== $exe  ($size MB)"

# 放一份到 build/sidecar/：windows/CMakeLists.txt 的 install 规则从这里取，随主程序装到应用目录旁
# （build/ 已 gitignore）。不放在 CARGO_TARGET_DIR 里让 CMake 去找，是因为那个路径是本机约定、
# 不该写进入库的 CMake 文件。
$drop = Join-Path $root "build\sidecar"
New-Item -ItemType Directory -Force $drop | Out-Null
Copy-Item $exe (Join-Path $drop "zed-agent-acp.exe") -Force
Write-Host "== dropped to $drop\zed-agent-acp.exe"

if ($Selftest) {
    # `--user-data-dir` 必须给：不给就写本机 Zed 自己的数据目录（threads.db / logs / prompts），
    # 违反规则 7「不动用户数据」，还会和正在跑的 Zed 抢 threads.db（R7 实测 `database is locked`）。
    # 产品路径本来就传（rust/acp-core/src/builtin.rs），开发自测得跟它一致（审查 finding，2026-09-22）。
    $selftestData = Join-Path $root "build\sidecar\selftest-data"
    New-Item -ItemType Directory -Force $selftestData | Out-Null
    # `--zed-settings` 跟着一起给（= 产品路径的「配置共用、数据隔离」，见 builtin.rs 的 entry()）：
    # 只给 --user-data-dir 的话 settings 从空目录里读，自检会报 `models: 0`，那一行就白报了。
    # 路径口径与 `settings::zed_import::zed_settings_path()` 一致；本机没装 Zed 就不传。
    $zedSettings = if ($env:APPDATA) { Join-Path $env:APPDATA "Zed\settings.json" } else { $null }
    $selftestArgs = @("--user-data-dir", $selftestData)
    if ($zedSettings -and (Test-Path $zedSettings)) { $selftestArgs += @("--zed-settings", $zedSettings) }
    Write-Host "== selftest ($($selftestArgs -join ' '))"
    & $exe @selftestArgs --selftest
    if ($LASTEXITCODE -ne 0) { throw "selftest failed ($LASTEXITCODE)" }
}
