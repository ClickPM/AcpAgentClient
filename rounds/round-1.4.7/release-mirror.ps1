# Mirror the fresh Release build into the daily install dir and smoke it there (ASCII only).
# 1.4.7 起包里没有 sidecar，/MIR 会把安装目录里遗留的 zed-agent-acp.exe 一并删掉。
#   powershell -File rounds\round-1.4.7\release-mirror.ps1
param(
    [string]$Version = "1.4.7"
)
$ErrorActionPreference = "Stop"
$src = "D:\variFlight_work\AcpAgentClient-release\build\windows\x64\runner\Release"
$dst = "D:\tools\AcpAgentClient"
$running = Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($dst, [System.StringComparison]::OrdinalIgnoreCase) }
if ($running) {
    $running | Select-Object ProcessId, Name, ExecutablePath | Format-Table -AutoSize | Out-String | Write-Host
    throw "app is running from the install dir; not mirroring"
}
robocopy $src $dst /MIR /NFL /NDL /NJH | Out-Host
$rc = $LASTEXITCODE
"robocopy exit $rc"
if ($rc -ge 8) { throw "robocopy failed" }
$a = Get-ChildItem $src -Recurse -File | ForEach-Object { $_.FullName.Substring($src.Length) }
$b = Get-ChildItem $dst -Recurse -File | ForEach-Object { $_.FullName.Substring($dst.Length) }
"files: src=$($a.Count) dst=$($b.Count)"
$diff = Compare-Object $a $b
if ($diff) { $diff | Format-Table -AutoSize | Out-String | Write-Host; throw "file lists differ" }
foreach ($f in @("acp_agent_client.exe", "acp_bridge.dll", "data\app.so", "data\flutter_assets\FontManifest.json")) {
    $h1 = (Get-FileHash (Join-Path $src $f) -Algorithm SHA256).Hash.ToLower()
    $h2 = (Get-FileHash (Join-Path $dst $f) -Algorithm SHA256).Hash.ToLower()
    $same = if ($h1 -eq $h2) { "same" } else { "DIFF" }
    "{0,-40} {1}  {2}" -f $f, $h1.Substring(0, 12), $same
    if ($h1 -ne $h2) { throw "hash mismatch: $f" }
}
$tmp = Join-Path $env:TEMP ("acp-smoke-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null
$report = Join-Path $tmp "smoke-report.json"
$oldAppData = $env:APPDATA
$env:APPDATA = $tmp
$env:ACP_SMOKE_REPORT = $report
try {
    $p = Start-Process -FilePath (Join-Path $dst "acp_agent_client.exe") -Wait -PassThru
} finally {
    $env:APPDATA = $oldAppData
    Remove-Item Env:\ACP_SMOKE_REPORT -ErrorAction SilentlyContinue
}
"smoke exit: $($p.ExitCode)"
if (-not (Test-Path $report)) { throw "no smoke report" }
$json = Get-Content $report -Raw -Encoding UTF8 | ConvertFrom-Json
Get-Content $report
if (-not $json.ok) { throw "smoke not ok" }
if ($json.init.coreVersion -ne $Version) { throw "coreVersion is $($json.init.coreVersion), expected $Version" }
if ($json.droppedEvents -ne 0) { throw "droppedEvents is $($json.droppedEvents)" }
$log = Get-ChildItem (Join-Path $tmp "AcpAgentClient\logs") -Filter "acp-*.log" | Select-Object -First 1
$banner = (Get-Content $log.FullName -Raw -Encoding UTF8) -split "`r?`n" | Where-Object { $_ -match 'core\s+AcpAgentClient' } | Select-Object -First 1
"banner: $banner"
if ($banner -notmatch [regex]::Escape($Version)) { throw "banner version mismatch" }
""
(Get-Item (Join-Path $dst "acp_agent_client.exe")).VersionInfo | Select-Object FileVersion, ProductVersion | Format-List | Out-String | Write-Host
if (Test-Path (Join-Path $dst "zed-agent-acp.exe")) { throw "stale sidecar still in the install dir" } else { "no zed-agent-acp.exe in the install dir: ok" }
Remove-Item $tmp -Recurse -Force
exit 0
