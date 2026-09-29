# Delete pre-1.4.7 build outputs that are dead or superseded (ASCII only).
# Kept: dist\AcpAgentClient-1.4.7-* (this release), build\windows\...\Release (this build),
# build\test_cache in the release worktree (newest), vendor\upstream, .dart_tool.
param([switch]$DryRun)
$ErrorActionPreference = "Continue"
$rel = "D:\variFlight_work\AcpAgentClient-release"
$main = "D:\variFlight_work\AcpAgentClient"

$dirs = @(
  (Join-Path $rel "dist\stage"),
  (Join-Path $main "build\sidecar"),
  (Join-Path $main "build\test_cache")
)
$files = @(
  (Join-Path $rel "dist\AcpAgentClient-1.4.6-windows-x64.zip"),
  (Join-Path $rel "dist\AcpAgentClient-1.4.6-setup.exe")
)

function Dir-Size([string]$p) {
  [long]((Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
}
function Clear-ReadOnly([string]$dir) {
  Get-ChildItem $dir -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { if ($_.IsReadOnly) { $_.IsReadOnly = $false } }
}

$freed = 0L
foreach ($d in $dirs) {
  if (-not (Test-Path $d)) { "SKIP  (absent)  $d"; continue }
  $item = Get-Item $d -Force
  if ($item.LinkType) { throw "refusing to recurse into a reparse point: $d" }
  $size = Dir-Size $d
  $freed += $size
  "DELETE dir   {0,10:N1} MB  {1}" -f ($size / 1MB), $d
  if (-not $DryRun) { Clear-ReadOnly $d; [System.IO.Directory]::Delete($d, $true) }
}
foreach ($f in $files) {
  if (-not (Test-Path $f)) { "SKIP  (absent)  $f"; continue }
  $size = (Get-Item $f -Force).Length
  $freed += $size
  "DELETE file  {0,10:N1} MB  {1}" -f ($size / 1MB), $f
  if (-not $DryRun) { [System.IO.File]::Delete($f) }
}
"---- freed {0:N2} GB" -f ($freed / 1GB)

if (-not $DryRun) {
  foreach ($d in $dirs) { if (Test-Path $d) { throw "still present: $d" } }
  foreach ($f in $files) { if (Test-Path $f) { throw "still present: $f" } }
  "---- kept"
  Get-ChildItem (Join-Path $rel "dist") -Force | ForEach-Object { "  dist\{0}" -f $_.Name }
  "  vendor\upstream entries: {0}" -f (@(Get-ChildItem (Join-Path $main "vendor\upstream") -Force).Count)
}
exit 0
