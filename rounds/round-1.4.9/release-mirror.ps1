# Mirror the verified package into the daily install directory, then smoke with isolated APPDATA.
# Derived from rounds/round-1.4.8/release-mirror.ps1; ASCII only for Windows PowerShell 5.1.
param([string]$Version = "1.4.9")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$src = Join-Path $root "dist\stage\AcpAgentClient-$Version-windows-x64"
$dst = "D:\tools\AcpAgentClient"
$exe = Join-Path $src "acp_agent_client.exe"
if ((Get-Item $exe).VersionInfo.ProductVersion -ne "$Version+1") { throw "source version mismatch" }
foreach ($p in @(Get-Process -Name acp_agent_client -ErrorAction SilentlyContinue)) {
    if (-not $p.Path) { throw "cannot determine running application path; not mirroring" }
    if ($p.Path.StartsWith("$dst\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "daily install is running (pid $($p.Id)); not mirroring"
    }
}
robocopy $src $dst /MIR /NFL /NDL /NJH | Out-Host
$rc = $LASTEXITCODE
"robocopy exit $rc"
if ($rc -ge 8) { throw "robocopy failed" }
$a = @(Get-ChildItem $src -Recurse -File)
$b = @(Get-ChildItem $dst -Recurse -File)
$namesA = @($a | ForEach-Object { $_.FullName.Substring($src.Length) })
$namesB = @($b | ForEach-Object { $_.FullName.Substring($dst.Length) })
if (Compare-Object $namesA $namesB) { throw "file lists differ" }
foreach ($f in $a) {
    $other = Join-Path $dst $f.FullName.Substring($src.Length).TrimStart('\')
    if ((Get-FileHash $f.FullName).Hash -ne (Get-FileHash $other).Hash) { throw "hash mismatch: $other" }
}
"all $($a.Count) files match the verified package"
$tmp = Join-Path $env:TEMP ("acp-smoke-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null
$report = Join-Path $tmp "smoke-report.json"
$oldAppData = $env:APPDATA
$oldReport = $env:ACP_SMOKE_REPORT
try {
    $env:APPDATA = $tmp
    $env:ACP_SMOKE_REPORT = $report
    $p = Start-Process -FilePath (Join-Path $dst "acp_agent_client.exe") -WorkingDirectory $dst -Wait -PassThru
} finally {
    $env:APPDATA = $oldAppData
    if ($null -eq $oldReport) { Remove-Item Env:\ACP_SMOKE_REPORT -ErrorAction SilentlyContinue }
    else { $env:ACP_SMOKE_REPORT = $oldReport }
}
if ($p.ExitCode -ne 0) { throw "installed smoke exit $($p.ExitCode)" }
if (-not (Test-Path $report)) { throw "no smoke report" }
$json = Get-Content $report -Raw -Encoding UTF8 | ConvertFrom-Json
Get-Content $report
if (-not $json.ok -or $json.init.coreVersion -ne $Version -or $json.droppedEvents -ne 0) {
    throw "installed smoke failed or wrong version"
}
$log = Get-ChildItem (Join-Path $tmp "AcpAgentClient\logs") -Filter "acp-*.log"
$banner = (Get-Content $log[0].FullName -Raw -Encoding UTF8) -split "`r?`n" |
    Where-Object { $_ -match 'core\s+AcpAgentClient' }
if ($banner -notmatch "AcpAgentClient $([regex]::Escape($Version)) \(release, windows/x86_64\)") {
    throw "installed banner mismatch"
}
"banner: $banner"
(Get-Item (Join-Path $dst "acp_agent_client.exe")).VersionInfo |
    Select-Object FileVersion, ProductVersion | Format-List | Out-String | Write-Host
Remove-Item $tmp -Recurse -Force
exit 0
