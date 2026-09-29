# 打包产物的自动化验收（R8 验收 1 的可自动化部分）。
#   powershell -File scripts/verify-package.ps1            # zip + 安装器都验
#   powershell -File scripts/verify-package.ps1 -ZipOnly   # 只验免安装 zip（跳过装 / 卸）
#
# 每一步都在**全新的空数据目录**上跑：把 %APPDATA% 指到临时目录，应用的数据目录（docs/design.md § 10）
# 就落在那儿 —— 这是本机能做到的「干净机首启」等价物。
#
# 验的是两件事：
#   1. 解压即用：zip 里的 exe 在空数据目录上能起核心、往返 ping（ACP_SMOKE_REPORT 无头自检）；
#   2. 安装器静默装 -> 同样跑通 -> 静默卸载后目录清干净。
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
$skipped = New-Object System.Collections.Generic.List[string]
function Check($title, [scriptblock]$body) {
    Write-Host ("---- " + $title)
    try { & $body; Write-Host ("PASS  " + $title) }
    catch { Write-Host ("FAIL  " + $title + ": " + $_.Exception.Message); $failures.Add($title) }
}

# 在一个全新的空 %APPDATA% 上跑一次无头自检，回传 (报告对象, 日志内容)。
function Invoke-Smoke([string]$exe, [string]$label) {
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("acp-verify-" + $label + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force $sandbox | Out-Null
    $sandboxes.Add($sandbox)
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

function Assert-Banner($result, [string]$label) {
    $banner = ($result.Log -split "`r?`n" | Where-Object { $_ -match 'core\s+AcpAgentClient' } | Select-Object -First 1)
    if (-not $banner) { throw "$label：日志里没有版本 banner 行" }
    Write-Host ("      banner: " + $banner)
    if ($banner -notmatch [regex]::Escape($version)) { throw "$label：banner 里的版本不是 $version" }
    if ($banner -notmatch 'release') { throw "$label：banner 说这不是 release 构建" }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("acp-verify-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$sandboxes = New-Object System.Collections.Generic.List[string]
$sandboxes.Add($work)

try {
    $zip = Join-Path $dist "$name.zip"
    $setup = Join-Path $dist "AcpAgentClient-$version-setup.exe"

    Check "zip 解压即用（空数据目录 + 无头往返）" {
        if (-not (Test-Path $zip)) { throw "没有 $zip（先跑 scripts/package.ps1）" }
        $dest = Join-Path $work "zip"
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
        $appDir = Join-Path $dest $name
        $exe = Join-Path $appDir "acp_agent_client.exe"
        if (-not (Test-Path $exe)) { throw "zip 里没有 $name/acp_agent_client.exe" }
        foreach ($f in @("LICENSE", "NOTICE", "acp_bridge.dll", "data/icudtl.dat", "data/app.so", "data/flutter_assets/AssetManifest.bin")) {
            if (-not (Test-Path (Join-Path $appDir $f))) { throw "zip 里缺 $f" }
        }
        $r = Invoke-Smoke $exe "zip"
        Assert-Banner $r "zip"
        $script:zipAppDir = $appDir
    }

    if (-not $ZipOnly) {
        $issPath = Join-Path $root "packaging/windows/acp-agent-client.iss"
        $iss = Get-Content $issPath -Raw -Encoding UTF8
        if ($iss -notmatch '(?m)^AppId=\{\{([0-9A-Fa-f-]{36})\}') { throw "读不出 $issPath 里的 AppId（格式变了？）" }
        $uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{$($Matches[1])}_is1"
        if (Test-Path $uninstallKey) {
            Write-Host "SKIP  安装器：本机已经装着一份同 AppId 的 AcpAgent Client"
            Write-Host "      ($uninstallKey)"
            $skipped.Add("安装器：静默装 -> 跑通 -> 静默卸载（本机已有同 AppId 的安装）")
        } else {
            Check "安装器：静默装 -> 跑通 -> 静默卸载" {
                if (-not (Test-Path $setup)) { throw "没有 $setup（先跑 scripts/package.ps1）" }
                if ($iss -match '(?m)^\[(UninstallDelete|InstallDelete)\]') { throw "iss 里有 [$($Matches[1])] 段，它会删安装目录之外的东西（规则 7）" }
                $target = Join-Path $work "installed"
                $exe = Join-Path $target "acp_agent_client.exe"
                $p = Start-Process -FilePath $setup -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/NOICONS", "/DIR=$target") -Wait -PassThru
                if ($p.ExitCode -ne 0) { throw "静默安装退出码 $($p.ExitCode)" }
                if (-not (Test-Path $exe)) { throw "装完没有 $exe" }
                try {
                    $r = Invoke-Smoke $exe "installed"
                    Assert-Banner $r "installed"
                } finally {
                    $uninstaller = Get-ChildItem $target -Filter "unins*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($uninstaller) {
                        Start-Process -FilePath $uninstaller.FullName -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART") -Wait | Out-Null
                        $deadline = (Get-Date).AddSeconds(60)
                        while ((Test-Path $exe) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
                    }
                }
                if (-not $uninstaller) { throw "装完没有卸载程序" }
                if (Test-Path $exe) { throw "卸载后 $exe 还在" }
                if (Test-Path $uninstallKey) { throw "卸载后 HKCU 的卸载注册还在：$uninstallKey" }
            }
        }
    }
} finally {
    foreach ($d in $sandboxes) {
        try { Remove-Item $d -Recurse -Force -ErrorAction Stop } catch { Write-Host ("NOTE  临时目录没删掉：" + $d) }
    }
}

Write-Host ""
if ($skipped.Count -gt 0) { Write-Host ("SKIPPED: " + ($skipped -join "; ")) }
if ($failures.Count -gt 0) {
    Write-Host ("VERIFY FAILED: " + ($failures -join "; "))
    exit 1
}
Write-Host "VERIFY OK"
exit 0
