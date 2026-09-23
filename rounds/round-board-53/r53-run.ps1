# round-board-53 acceptance 7 (rule 9): real headless runs of the registry upgrade on Windows.
# Every run gets APPDATA pointed at a clean directory under $Root (data dir = $APPDATA\AcpAgentClient);
# reports land in $Root\<name>-report.json. Steps:
#   a1  fresh install of pi-acp (npx, versioned layout)
#   a2  install.json "version" rewritten to 0.0.1 -> upgrade (target dir name collides with the one in use -> suffixed)
#   a3  legacy layout rebuilt by hand (node_modules at the agent root) -> upgrade (npm must not install into the parent)
#   a4  plain start -> startup sweep removes the old version dirs and the legacy root files
#   b1  fresh install of codex-acp
#   b2  version rewritten -> new session (connected) -> upgrade -> reloadPending -> Reload Agent -> cleared
#   b3  plain start -> startup sweep removes the directory the old connection was using
# Usage: powershell -File rounds\round-board-53\r53-run.ps1 -Exe <acp_agent_client.exe> [-Only a|b]
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Root = "D:\cargo-target\AcpAgentClient-upgrade\r53-data",
    [string]$Cwd = "D:\variFlight_work\AcpAgentClient-upgrade",
    [string]$Only = ""
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $Root | Out-Null

function Invoke-Run([string]$Name, [string]$DataHome, [hashtable]$Vars) {
    New-Item -ItemType Directory -Force $DataHome | Out-Null
    $report = Join-Path $Root "$Name-report.json"
    if (Test-Path $report) { Remove-Item $report }
    $psi = New-Object System.Diagnostics.ProcessStartInfo $Exe
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables["APPDATA"] = $DataHome
    $psi.EnvironmentVariables["ACP_R5_REPORT"] = $report
    foreach ($k in $Vars.Keys) { $psi.EnvironmentVariables[$k] = [string]$Vars[$k] }
    $started = Get-Date
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    $secs = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    Write-Host ("[{0}] exit={1} {2}s report={3}" -f $Name, $p.ExitCode, $secs, $report)
}

function Get-Manifest([string]$DataHome, [string]$Id) {
    $path = Join-Path $DataHome "AcpAgentClient\agents\$Id\install.json"
    return @{ Path = $path; Json = (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
}

function Save-Manifest($m) {
    $text = $m.Json | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($m.Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-OldVersion([string]$DataHome, [string]$Id) {
    $m = Get-Manifest $DataHome $Id
    $m.Json.version = "0.0.1"
    Save-Manifest $m
    Write-Host ("  install.json version -> 0.0.1 (dir {0})" -f $m.Json.dir)
}

function Show-AgentDir([string]$DataHome, [string]$Id) {
    $dir = Join-Path $DataHome "AcpAgentClient\agents\$Id"
    $names = (Get-ChildItem -Force $dir | ForEach-Object { $_.Name }) -join ", "
    $m = Get-Manifest $DataHome $Id
    Write-Host ("  agents\{0}: {1}" -f $Id, $names)
    Write-Host ("  install.json: version={0} dir={1} previousVersion={2}" -f $m.Json.version, $m.Json.dir, $m.Json.previousVersion)
}

if ($Only -eq "" -or $Only -eq "a") {
    $a = Join-Path $Root "a"
    if (Test-Path $a) { [System.IO.Directory]::Delete($a, $true) }
    Invoke-Run "a1-install" $a @{ ACP_R5_REFRESH = "1"; ACP_R5_INSTALL = "pi-acp" }
    Show-AgentDir $a "pi-acp"

    Set-OldVersion $a "pi-acp"
    Invoke-Run "a2-upgrade-collision" $a @{ ACP_R5_UPGRADE = "pi-acp" }
    Show-AgentDir $a "pi-acp"

    # Legacy layout: move node_modules + package files of the current version dir up to the agent root.
    $m = Get-Manifest $a "pi-acp"
    $agentDir = Split-Path -Parent $m.Path
    $cur = $m.Json.dir
    foreach ($n in @("node_modules", "package.json", "package-lock.json")) {
        Move-Item (Join-Path $cur $n) (Join-Path $agentDir $n)
    }
    [System.IO.Directory]::Delete($cur, $true)
    $m.Json.dir = $agentDir
    $m.Json.args[0] = $m.Json.args[0].Replace($cur, $agentDir)
    $m.Json.version = "0.0.1"
    Save-Manifest $m
    Write-Host ("  legacy layout: dir={0} entry={1}" -f $m.Json.dir, $m.Json.args[0])
    Show-AgentDir $a "pi-acp"
    Invoke-Run "a3-upgrade-legacy" $a @{ ACP_R5_UPGRADE = "pi-acp" }
    Show-AgentDir $a "pi-acp"

    # Old version dirs (and the legacy root files) are left for the next start; a plain start sweeps them.
    Invoke-Run "a4-restart-sweep" $a @{ ACP_R5_REFRESH = "1" }
    Start-Sleep -Seconds 1
    Show-AgentDir $a "pi-acp"
}

if ($Only -eq "" -or $Only -eq "b") {
    $b = Join-Path $Root "b"
    if (Test-Path $b) { [System.IO.Directory]::Delete($b, $true) }
    Invoke-Run "b1-install" $b @{ ACP_R5_REFRESH = "1"; ACP_R5_INSTALL = "codex-acp" }
    Show-AgentDir $b "codex-acp"

    Set-OldVersion $b "codex-acp"
    Invoke-Run "b2-upgrade-connected" $b @{ ACP_R5_AGENT = "codex-acp"; ACP_R5_CWD = $Cwd; ACP_R5_UPGRADE = "codex-acp"; ACP_R5_RELOAD = "1" }
    Show-AgentDir $b "codex-acp"

    Invoke-Run "b3-restart-sweep" $b @{ ACP_R5_REFRESH = "1" }
    Start-Sleep -Seconds 1
    Show-AgentDir $b "codex-acp"
}
