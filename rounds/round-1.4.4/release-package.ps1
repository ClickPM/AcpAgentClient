# Package + verify 1.4.4 in the release worktree (ASCII only; run with powershell -File).
$ErrorActionPreference = "Stop"
$wt = "D:\variFlight_work\AcpAgentClient-release"
Set-Location $wt
"branch: " + (& git branch --show-current) + " @ " + (& git rev-parse --short HEAD)
$sc = Join-Path $wt "build\sidecar\zed-agent-acp.exe"
if (-not (Test-Path $sc)) { throw "sidecar missing at $sc" }
"sidecar sha256: " + (Get-FileHash $sc -Algorithm SHA256).Hash.ToLower().Substring(0, 12)
$t0 = Get-Date
powershell -File scripts\package.ps1
if ($LASTEXITCODE -ne 0) { throw "package.ps1 failed (exit $LASTEXITCODE)" }
"package.ps1 took {0:N0} s" -f ((Get-Date) - $t0).TotalSeconds
$t1 = Get-Date
powershell -File scripts\verify-package.ps1
if ($LASTEXITCODE -ne 0) { throw "verify-package.ps1 failed (exit $LASTEXITCODE)" }
"verify-package.ps1 took {0:N0} s" -f ((Get-Date) - $t1).TotalSeconds
"---- dist"
Get-ChildItem (Join-Path $wt "dist\AcpAgentClient-1.4.4-*") | ForEach-Object {
  "{0}  {1:N1} MB  {2}" -f $_.Name, ($_.Length / 1MB), (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
}
exit 0
