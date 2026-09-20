# R7.5 headless equivalence runner (fake-agent, isolated APPDATA + fresh project copy per run).
#   powershell -File D:\cargo-target\AcpAgentClient\r75\run-report.ps1 -Kind r3|r5|r6 -Label <label> [-Exe <exe>]
# Report -> D:\cargo-target\AcpAgentClient\r75\reports\<label>\<kind>.json ; prints "exit=<code> ok=<bool>".
param(
    [Parameter(Mandatory = $true)][ValidateSet("r3", "r5", "r6")][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Label,
    [string]$Exe = "D:\variFlight_work\AcpAgentClient\.claude\worktrees\r7-5-composition-root-refactor-7600bf\build\windows\x64\runner\Release\acp_agent_client.exe",
    [int]$TimeoutSec = 420
)
$ErrorActionPreference = "Stop"
$root = "D:\cargo-target\AcpAgentClient\r75"
$run = Join-Path $root "run"
$template = Join-Path $root "template"
$reportDir = Join-Path $root ("reports\" + $Label)
New-Item -ItemType Directory -Force $reportDir | Out-Null
$report = Join-Path $reportDir ($Kind + ".json")
if (Test-Path $report) { Remove-Item $report -Force }

# Stale instances from this worktree only (never touch the owner's installed app).
$exeDir = Split-Path -Parent $Exe
Get-Process acp_agent_client -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($exeDir, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object {
    Write-Host ("killing stale instance pid " + $_.Id)
    & taskkill /T /F /PID $_.Id | Out-Null
}

# Fresh run dir from template.
if (Test-Path $run) { Remove-Item -Recurse -Force $run }
New-Item -ItemType Directory -Force $run | Out-Null
Copy-Item -Recurse (Join-Path $template "appdata") (Join-Path $run "appdata")
Copy-Item -Recurse (Join-Path $template "proj") (Join-Path $run "proj")
$proj = Join-Path $run "proj"

# Clean env.
Get-ChildItem Env: | Where-Object { $_.Name -like "ACP_R*" } | ForEach-Object { Set-Item -Path ("Env:" + $_.Name) -Value "" }
$env:APPDATA = Join-Path $run "appdata"

switch ($Kind) {
    "r3" {
        $env:ACP_R3_REPORT = $report
        $env:ACP_R3_AGENT = "fake-r3"
        $env:ACP_R3_CWD = $proj
        $env:ACP_R3_CONFIG = "mode=code"
        $env:ACP_R3_PROMPT = "r75 first turn"
        $env:ACP_R3_PROMPT2 = "r75 second turn"
        $env:ACP_R3_CANCEL_AFTER = "2"
        $env:ACP_R3_PERMISSION = "allow_once"
        $env:ACP_R3_NEW_BRANCH = "r75-branch"
        $env:ACP_R3_KILL = "1"
        $env:ACP_R3_TIMEOUT = "120"
        $env:ACP_R4_KILL_BG_AFTER = "2"
        $env:ACP_R4_LOCAL_SHELL = "1"
        $env:ACP_R4_FILES = "1"
        $env:ACP_R4_FOLLOW = "1"
    }
    "r5" {
        $env:ACP_R5_REPORT = $report
        $env:ACP_R5_CWD = $proj
        $env:ACP_R5_AGENT = "fake-r5"
        $env:ACP_R5_AUTH_METHOD = "fake-url"
        $env:ACP_R5_AUTH_TIMEOUT = "60"
        $env:ACP_R5_PROMPT = "r75 auth turn"
        $env:ACP_R5_IMPORT_ZED = "1"
        $env:ACP_R5_TIMEOUT = "120"
    }
    "r6" {
        $env:ACP_R6_REPORT = $report
        $env:ACP_R6_CWD = $proj
        $env:ACP_R6_AGENT = "fake-r6"
        $env:ACP_R6_PROMPT = "r75 first"
        $env:ACP_R6_PROMPT2 = "r75 second"
        $env:ACP_R6_PROMPT3 = "r75 third"
        $env:ACP_R6_CANCEL_AFTER = "2"
        $env:ACP_R6_PERMISSION = "allow_once"
        $env:ACP_R6_MODE = "ask"
        $env:ACP_R6_RELOAD = "1"
        $env:ACP_R6_CLOSE = "1"
        $env:ACP_R6_RESUME = "1"
        $env:ACP_R6_DELETE = "1"
        $env:ACP_R6_TIMEOUT = "120"
    }
}

Write-Host ("== " + $Kind + " -> " + $report)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath $Exe -WorkingDirectory $exeDir -PassThru -WindowStyle Hidden
if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    Write-Host ("TIMEOUT after " + $TimeoutSec + "s; killing pid " + $p.Id)
    & taskkill /T /F /PID $p.Id | Out-Null
    Write-Host "exit=timeout ok=False"
    exit 2
}
$sw.Stop()
$ok = "missing"
if (Test-Path $report) {
    try {
        $j = Get-Content $report -Raw -Encoding UTF8 | ConvertFrom-Json
        $ok = $j.ok
    } catch { $ok = "unparsable" }
}
Write-Host ("exit=" + $p.ExitCode + " ok=" + $ok + " elapsed=" + [int]$sw.Elapsed.TotalSeconds + "s")
exit $p.ExitCode
