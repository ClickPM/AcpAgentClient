# Mirror the fresh Release build into the daily install dir and smoke it there (ASCII only).
$ErrorActionPreference = "Stop"
$src = "D:\variFlight_work\AcpAgentClient-release\build\windows\x64\runner\Release"
$dst = "D:\tools\AcpAgentClient"
$running = Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($dst, [System.StringComparison]::OrdinalIgnoreCase) }
if ($running) {
  $running | Select-Object ProcessId, Name, ExecutablePath | Format-Table -AutoSize | Out-String | Write-Host
  throw "app is running from the install dir; not mirroring"
}
$sidecarSame = (Get-FileHash (Join-Path $src "zed-agent-acp.exe") -Algorithm SHA256).Hash -eq (Get-FileHash (Join-Path $dst "zed-agent-acp.exe") -Algorithm SHA256).Hash
"sidecar unchanged: $sidecarSame"
if ($sidecarSame) {
  robocopy $src $dst /MIR /XF zed-agent-acp.exe /NFL /NDL /NJH | Out-Host
} else {
  robocopy $src $dst /MIR /NFL /NDL /NJH | Out-Host
}
$rc = $LASTEXITCODE
"robocopy exit $rc"
if ($rc -ge 8) { throw "robocopy failed" }
$a = Get-ChildItem $src -Recurse -File | ForEach-Object { $_.FullName.Substring($src.Length) }
$b = Get-ChildItem $dst -Recurse -File | ForEach-Object { $_.FullName.Substring($dst.Length) }
"files: src=$($a.Count) dst=$($b.Count)"
$diff = Compare-Object $a $b
if ($diff) { $diff | Format-Table -AutoSize | Out-String | Write-Host; throw "file lists differ" }
foreach ($f in @("acp_agent_client.exe", "acp_bridge.dll", "zed-agent-acp.exe", "data\app.so", "data\flutter_assets\FontManifest.json")) {
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
if (Test-Path $report) { Get-Content $report } else { throw "no smoke report" }
""
(Get-Item (Join-Path $dst "acp_agent_client.exe")).VersionInfo | Select-Object FileVersion, ProductVersion | Format-List | Out-String | Write-Host
"zed-agent-acp --version: " + (& (Join-Path $dst "zed-agent-acp.exe") --version)
Remove-Item $tmp -Recurse -Force
exit 0
