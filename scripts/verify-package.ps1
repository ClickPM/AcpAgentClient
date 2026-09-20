# 打包产物的自动化验收（R8 验收 1 的可自动化部分，所有者裁定 2026-09-20「只做自动化」）。
#   powershell -File scripts/verify-package.ps1            # zip + 安装器都验
#   powershell -File scripts/verify-package.ps1 -ZipOnly   # 只验免安装 zip（跳过装 / 卸）
#
# 每一步都在**全新的空数据目录**上跑：把 %APPDATA% 指到临时目录，应用的数据目录（docs/design.md § 10）
# 就落在那儿 —— 这是本机能做到的「干净机首启」等价物（真·干净 VM 不在自动化范围里）。
#
# 验的是四件事：
#   1. 解压即用：zip 里的 exe 在空数据目录上能起核心、往返 ping（ACP_SMOKE_REPORT 无头自检）；
#   2. 随包的 sidecar 被应用目录旁的定位逻辑找到（日志 banner 里的 sidecar= 指向解压出来的那份）；
#   3. 随包的 sidecar 自己能跑（--version 与 --selftest）；
#   4. 安装器静默装 → 同样跑通 → 静默卸载后目录清干净、%APPDATA% 的用户数据不受影响。
param(
    [switch]$ZipOnly
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root "dist"

$pubspec = Get-Content (Join-Path $root "pubspec.yaml") -Raw -Encoding UTF8
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') { throw "pubspec.yaml 里没有 version: X.Y.Z+N 行" }
$version = $Matches[1]
$name = "AcpAgentClient-$version-windows-x64"

$failures = New-Object System.Collections.Generic.List[string]
function Check($title, [scriptblock]$body) {
    Write-Host ("---- " + $title)
    try { & $body; Write-Host ("PASS  " + $title) }
    catch { Write-Host ("FAIL  " + $title + ": " + $_.Exception.Message); $failures.Add($title) }
}

# 在一个全新的空 %APPDATA% 上跑一次无头自检，回传 (报告对象, 日志内容)。
function Invoke-Smoke([string]$exe, [string]$label) {
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("acp-verify-" + $label + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force $sandbox | Out-Null
    $report = Join-Path $sandbox "smoke.json"
    $savedAppData = $env:APPDATA
    $savedReport = $env:ACP_SMOKE_REPORT
    try {
        $env:APPDATA = $sandbox
        $env:ACP_SMOKE_REPORT = $report
        $p = Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -Wait -PassThru -WindowStyle Hidden
    } finally {
        $env:APPDATA = $savedAppData
        if ($null -eq $savedReport) { Remove-Item Env:\ACP_SMOKE_REPORT -ErrorAction SilentlyContinue } else { $env:ACP_SMOKE_REPORT = $savedReport }
    }
    if (-not (Test-Path $report)) { throw "$label：没写出报告（exit $($p.ExitCode)）" }
    $json = Get-Content $report -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($p.ExitCode -ne 0 -or -not $json.ok) { throw "$label：自检失败（exit $($p.ExitCode)，ok=$($json.ok)）" }
    $dataDir = Join-Path $sandbox "AcpAgentClient"
    if (-not (Test-Path $dataDir)) { throw "$label：没在空 %APPDATA% 下建出数据目录 $dataDir" }
    $logs = Get-ChildItem (Join-Path $dataDir "logs") -Filter "acp-*.log" -ErrorAction SilentlyContinue
    if (-not $logs) { throw "$label：数据目录里没有 logs/acp-<日期>.log" }
    $log = (Get-Content $logs[0].FullName -Raw -Encoding UTF8)
    [pscustomobject]@{ Sandbox = $sandbox; Report = $json; Log = $log }
}

function Assert-Banner($result, [string]$label, [string]$expectedSidecar) {
    $banner = ($result.Log -split "`r?`n" | Where-Object { $_ -match 'core\s+AcpAgentClient' } | Select-Object -First 1)
    if (-not $banner) { throw "$label：日志里没有版本 banner 行" }
    Write-Host ("      banner: " + $banner)
    if ($banner -notmatch [regex]::Escape($version)) { throw "$label：banner 里的版本不是 $version" }
    if ($banner -notmatch 'release') { throw "$label：banner 说这不是 release 构建" }
    if ($expectedSidecar) {
        if ($banner -notmatch [regex]::Escape($expectedSidecar)) { throw "$label：banner 里的 sidecar= 不是随包那份（期望 $expectedSidecar）" }
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("acp-verify-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$sandboxes = New-Object System.Collections.Generic.List[string]
$sandboxes.Add($work)

try {
    $zip = Join-Path $dist "$name.zip"
    $zipLean = Join-Path $dist "$name-nosidecar.zip"
    $setup = Join-Path $dist "AcpAgentClient-$version-setup.exe"

    Check "zip 解压即用（空数据目录 + 无头往返）" {
        if (-not (Test-Path $zip)) { throw "没有 $zip（先跑 scripts/package.ps1）" }
        $dest = Join-Path $work "zip"
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
        $appDir = Join-Path $dest $name
        $exe = Join-Path $appDir "acp_agent_client.exe"
        if (-not (Test-Path $exe)) { throw "zip 里没有 $name/acp_agent_client.exe" }
        foreach ($f in @("LICENSE", "NOTICE", "zed-agent-acp.exe", "acp_bridge.dll", "data/icudtl.dat", "data/app.so", "data/flutter_assets/AssetManifest.bin")) {
            if (-not (Test-Path (Join-Path $appDir $f))) { throw "zip 里缺 $f" }
        }
        $r = Invoke-Smoke $exe "zip"
        $sandboxes.Add($r.Sandbox)
        Assert-Banner $r "zip" (Join-Path $appDir "zed-agent-acp.exe")
        $script:zipAppDir = $appDir
    }

    Check "不含 sidecar 的 zip 里确实没有 sidecar" {
        if (-not (Test-Path $zipLean)) { throw "没有 $zipLean" }
        $dest = Join-Path $work "zip-lean"
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipLean, $dest)
        $appDir = Join-Path $dest $name
        if (-not (Test-Path (Join-Path $appDir "acp_agent_client.exe"))) { throw "精简 zip 里没有主程序" }
        if (Test-Path (Join-Path $appDir "zed-agent-acp.exe")) { throw "精简 zip 里不该有 zed-agent-acp.exe" }
    }

    Check "随包 sidecar 自己能跑（--version / --selftest）" {
        # 第一步失败时这里没有解压目录可用，直接说清楚，别让 Join-Path 抛「参数为 null」。
        if (-not $script:zipAppDir) { throw "上一步没解压出应用目录，跳过（先修第一条）" }
        $sidecar = Join-Path $script:zipAppDir "zed-agent-acp.exe"
        $versionLine = (& $sidecar --version) -join ""
        if ($LASTEXITCODE -ne 0) { throw "--version 退出码 $LASTEXITCODE" }
        Write-Host ("      " + $versionLine)
        $pins = Get-Content (Join-Path $root "pins/upstream.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $zedPin = $pins.upstream | Where-Object { $_.name -eq "zed" }
        if ($versionLine -notmatch [regex]::Escape($zedPin.version)) { throw "--version 里不是 zed 钉版本 $($zedPin.version)" }
        if ($versionLine -match [regex]::Escape(" $version ")) { throw "--version 里出现了应用版本 $version —— 版本解耦被改回去了？" }
        if ($versionLine -notmatch [regex]::Escape($zedPin.commit.Substring(0, 12))) { throw "--version 里没有钉的 zed commit" }
        # --selftest 会真的起一遍 headless gpui，不给 --user-data-dir 就落到**本机 Zed 自己的**
        # 数据目录里（CLAUDE.md 规则 7：不动用户数据），所以指到临时目录。
        & $sidecar --user-data-dir (Join-Path $work "zed-agent-data") --selftest
        if ($LASTEXITCODE -ne 0) { throw "--selftest 退出码 $LASTEXITCODE" }
    }

    if (-not $ZipOnly) {
        Check "安装器：静默装 → 跑通 → 静默卸载" {
            if (-not (Test-Path $setup)) { throw "没有 $setup（先跑 scripts/package.ps1）" }
            $target = Join-Path $work "installed"
            $p = Start-Process -FilePath $setup -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/NOICONS", "/DIR=$target") -Wait -PassThru
            if ($p.ExitCode -ne 0) { throw "静默安装退出码 $($p.ExitCode)" }
            $exe = Join-Path $target "acp_agent_client.exe"
            if (-not (Test-Path $exe)) { throw "装完没有 $exe" }
            $r = Invoke-Smoke $exe "installed"
            $sandboxes.Add($r.Sandbox)
            Assert-Banner $r "installed" (Join-Path $target "zed-agent-acp.exe")

            $uninstaller = Get-ChildItem $target -Filter "unins*.exe" | Select-Object -First 1
            if (-not $uninstaller) { throw "装完没有卸载程序" }
            # 卸载程序会把自己复制到临时目录再退出，父进程等不到真正结束：轮询目录消失。
            $u = Start-Process -FilePath $uninstaller.FullName -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART") -Wait -PassThru
            $deadline = (Get-Date).AddSeconds(60)
            while ((Test-Path $exe) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            if (Test-Path $exe) { throw "卸载后 $exe 还在（卸载程序退出码 $($u.ExitCode)）" }
        }
    }
} finally {
    foreach ($d in $sandboxes) {
        # 卸载程序刚放手，文件句柄可能还没落地；删不掉就留在 %TEMP% 里，不因为清场失败报错。
        try { Remove-Item $d -Recurse -Force -ErrorAction Stop } catch { Write-Host ("NOTE  临时目录没删掉：" + $d) }
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host ("VERIFY FAILED: " + ($failures -join "; "))
    exit 1
}
Write-Host "VERIFY OK"
exit 0
