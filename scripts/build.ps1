# Windows release 构建（R0）：flutter build windows --release，Rust 核心由 cargokit 在 windows/CMakeLists.txt 里随 runner 构建。
#   powershell -File scripts/build.ps1                # release
#   powershell -File scripts/build.ps1 -Debug         # debug（flutter run 用的同一套产物）
#   powershell -File scripts/build.ps1 -Smoke         # 构建后跑一次无头往返自检（ACP_SMOKE_REPORT）
# CARGO_TARGET_DIR 固定到纯 ASCII 路径（所有者裁定 2026-09-15，docs/research.md § 9.3）；
# cargokit 的 cmake 会把它接成 cargo 的 --target-dir（cargokit/cmake/cargokit.cmake 的本项目补丁）。
param(
    [switch]$Debug,
    [switch]$Smoke,
    [string]$CargoTargetDir = "D:\cargo-target\AcpAgentClient"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    New-Item -ItemType Directory -Force $CargoTargetDir | Out-Null
    $env:CARGO_TARGET_DIR = $CargoTargetDir
    $mode = if ($Debug) { "debug" } else { "release" }

    # Flutter 的 Windows 构建链（flutter_assemble 的 MSBuild 自定义生成规则）会把项目路径按系统代码页转码，
    # 项目路径含中文时 app.dill 的路径变成「锟斤拷」而失败（R0 实测，与 Rust 部分无关）。
    # 对策：路径含非 ASCII 字符时，在纯 ASCII 的 CargoTargetDir 下建一个目录联接（junction，不需要开发者模式）指向项目根，
    # 从联接路径起构建；产物仍落在项目自己的 build/ 里。联接只删链接本身，绝不递归删目标。
    $buildRoot = $root
    if ($root -match '[^ -~]') {   # 任一非可打印 ASCII 字符（中文、全角等）
        $link = Join-Path $CargoTargetDir "ascii-root"
        if (Test-Path $link) { [System.IO.Directory]::Delete($link, $false) }
        & cmd /c mklink /J "$link" "$root" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "mklink /J failed for $root" }
        $buildRoot = $link
        Write-Host "== project path is non-ASCII; building through junction $link -> $root"
    }

    Write-Host "== flutter build windows --$mode  (CARGO_TARGET_DIR=$CargoTargetDir)"
    Push-Location $buildRoot
    try {
        & flutter build windows "--$mode"
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed ($LASTEXITCODE)" }
    } finally { Pop-Location }

    $config = if ($Debug) { "Debug" } else { "Release" }
    $outDir = Join-Path $root "build\windows\x64\runner\$config"
    $exe = Join-Path $outDir "acp_agent_client.exe"
    $dll = Join-Path $outDir "acp_bridge.dll"
    foreach ($f in @($exe, $dll)) {
        if (-not (Test-Path $f)) { throw "expected build output missing: $f" }
    }
    Write-Host ("OK  {0}  ({1:N0} bytes)" -f $exe, (Get-Item $exe).Length)
    Write-Host ("OK  {0}  ({1:N0} bytes)" -f $dll, (Get-Item $dll).Length)

    if ($Smoke) {
        $report = Join-Path $root "build\smoke-report.json"
        if (Test-Path $report) { Remove-Item $report -Force }
        Write-Host "== smoke: $exe  (ACP_SMOKE_REPORT=$report)"
        $env:ACP_SMOKE_REPORT = $report
        try {
            $p = Start-Process -FilePath $exe -WorkingDirectory $outDir -Wait -PassThru -WindowStyle Hidden
        } finally {
            Remove-Item Env:\ACP_SMOKE_REPORT -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path $report)) { throw "smoke produced no report (exit $($p.ExitCode))" }
        Get-Content $report -Raw -Encoding UTF8 | Write-Host
        if ($p.ExitCode -ne 0) { throw "smoke failed (exit $($p.ExitCode))" }
        Write-Host "OK  smoke round trip"
    }
} finally {
    Pop-Location
}
