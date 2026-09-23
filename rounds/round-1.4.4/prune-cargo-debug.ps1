# Prune D:\cargo-target\AcpAgentClient\debug down to what the current sources use (ASCII only).
# In-use set = every 16-hex hash cargo itself reports for the three validate commands
# (compiler-artifact filenames + build-script-executed out_dir). deps files and build dirs whose
# hash is not in the set are deleted; incremental is deleted entirely. Afterwards the same three
# commands are re-run and must not recompile anything.
param([switch]$DryRun)
$rust = "D:\variFlight_work\AcpAgentClient-release\rust"
$target = "D:\cargo-target\AcpAgentClient"
$env:CARGO_TARGET_DIR = $target
Set-Location $rust
$ErrorActionPreference = "Continue"

$hashes = New-Object 'System.Collections.Generic.HashSet[string]'
function Collect([string[]]$lines, [string]$label) {
  $units = 0
  foreach ($line in $lines) {
    if (-not ($line -is [string]) -or -not $line.StartsWith("{")) { continue }
    try { $m = $line | ConvertFrom-Json } catch { continue }
    $paths = @()
    if ($m.reason -eq "compiler-artifact") { $paths += $m.filenames; $units++ }
    elseif ($m.reason -eq "build-script-executed") { $paths += $m.out_dir; $units++ }
    foreach ($p in $paths) {
      foreach ($mt in [regex]::Matches([string]$p, '-([0-9a-f]{16})(\.|\\|/|$)')) { [void]$hashes.Add($mt.Groups[1].Value) }
    }
  }
  "$label : $units units, $($hashes.Count) hashes so far"
}
function Run([string[]]$cmdArgs) {
  $out = & cargo @cmdArgs 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { throw "cargo $($cmdArgs -join ' ') failed (exit $LASTEXITCODE)" }
  return ,$out
}
$t0 = Get-Date
Collect (Run @("build", "--workspace", "--locked", "--message-format=json")) "build"
Collect (Run @("test", "--workspace", "--locked", "--no-run", "--message-format=json")) "test --no-run"
Collect (Run @("clippy", "--workspace", "--all-targets", "--locked", "--message-format=json", "--", "-D", "warnings")) "clippy"
"collected in {0:N0} s; in-use hashes: {1}" -f ((Get-Date) - $t0).TotalSeconds, $hashes.Count
if ($hashes.Count -lt 100) { throw "suspiciously few hashes; aborting" }

function Clear-ReadOnly([string]$dir) {
  Get-ChildItem $dir -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { if ($_.IsReadOnly) { $_.IsReadOnly = $false } }
}

$deps = Join-Path $target "debug\deps"
$freed = 0L; $n = 0; $kept = 0
foreach ($f in Get-ChildItem $deps -File -Force) {
  if ($f.Name -notmatch '-([0-9a-f]{16})(\.|$)') { continue }
  if ($hashes.Contains($Matches[1])) { $kept++; continue }
  $freed += $f.Length; $n++
  if (-not $DryRun) { [System.IO.File]::Delete($f.FullName) }
}
"deps: delete {0} files ({1:N2} GB), keep {2}" -f $n, ($freed / 1GB), $kept

$bd = Join-Path $target "debug\build"
$freedB = 0L; $nb = 0; $keptB = 0
foreach ($d in Get-ChildItem $bd -Directory -Force) {
  if ($d.Name -notmatch '-([0-9a-f]{16})$') { continue }
  if ($hashes.Contains($Matches[1])) { $keptB++; continue }
  $size = (Get-ChildItem $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  $freedB += [long]$size; $nb++
  if (-not $DryRun) { Clear-ReadOnly $d.FullName; [System.IO.Directory]::Delete($d.FullName, $true) }
}
"build dirs: delete {0} ({1:N2} GB), keep {2}" -f $nb, ($freedB / 1GB), $keptB

$inc = Join-Path $target "debug\incremental"
if (Test-Path $inc) {
  $size = (Get-ChildItem $inc -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  "incremental: delete {0:N2} GB" -f ([long]$size / 1GB)
  if (-not $DryRun) { Clear-ReadOnly $inc; [System.IO.Directory]::Delete($inc, $true) }
}
if ($DryRun) { "dry run, nothing deleted"; exit 0 }

"---- re-check freshness"
$stale = 0
foreach ($cmdArgs in @(
    @("build", "--workspace", "--locked"),
    @("test", "--workspace", "--locked", "--no-run"),
    @("clippy", "--workspace", "--all-targets", "--locked", "--", "-D", "warnings"))) {
  $out = & cargo @cmdArgs 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { throw "re-check cargo $($cmdArgs -join ' ') failed" }
  $c = @($out | Where-Object { $_ -match '^\s*Compiling ' }).Count
  "cargo $($cmdArgs[0]): recompiled $c units"
  $stale += $c
}
if ($stale -ne 0) { throw "pruning caused $stale recompiles" }
"debug now: {0:N2} GB" -f ((Get-ChildItem (Join-Path $target "debug") -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB)
exit 0
