# Remove worktrees + local branches already merged into main (claude/* only), then empty shells
# and the per-branch cargo target dirs those branches own (ASCII only).
#   powershell -File rounds\round-1.4.8\cleanup-worktrees.ps1
param(
  [switch]$DryRun,
  [string[]]$AlsoBranches = @(),
  [string[]]$ExtraTargets = @()
)
$ErrorActionPreference = "Continue"
$repo = "D:\variFlight_work\AcpAgentClient"
Set-Location $repo
$guard = Join-Path $repo "vendor\upstream\agent-client-protocol\Cargo.toml"
if (-not (Test-Path $guard)) { throw "guard file missing before start: $guard" }
$upstreamCount = @(Get-ChildItem (Join-Path $repo "vendor\upstream") -Force).Count
"vendor\upstream entries: $upstreamCount"

$merged = @(& git branch --merged main --format='%(refname:short)') | Where-Object { $_ -like 'claude/*' -or $AlsoBranches -contains $_ }
"merged branches to remove: $($merged -join ', ')"

# path -> branch from git worktree list --porcelain
$wts = @{}
$cur = $null
foreach ($line in (& git worktree list --porcelain)) {
  if ($line -like 'worktree *') { $cur = $line.Substring(9) }
  elseif ($line -like 'branch refs/heads/*' -and $cur) { $wts[$cur] = $line.Substring(18) }
}

function Remove-ReparsePoints([string]$dir) {
  $win = $dir -replace '/', '\'
  $links = @(& cmd /c "dir `"$win`" /al /s /b 2>nul") | Where-Object { $_ }
  if ($links.Count -eq 0) { return }
  "  reparse points in $dir : $($links.Count)"
  foreach ($l in ($links | Sort-Object { $_.Length } -Descending)) {
    "    unlink $l"
    if (-not $DryRun) { [System.IO.Directory]::Delete($l, $false) }
  }
  $left = @(& cmd /c "dir `"$win`" /al /s /b 2>nul") | Where-Object { $_ }
  if (-not $DryRun -and $left.Count -ne 0) { throw "reparse points still present in $dir" }
}

function Dir-Size([string]$p) {
  [long]((Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
}
function Clear-ReadOnly([string]$dir) {
  Get-ChildItem $dir -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { if ($_.IsReadOnly) { $_.IsReadOnly = $false } }
}

foreach ($path in $wts.Keys) {
  $b = $wts[$path]
  if ($merged -notcontains $b) { continue }
  if ($path -replace '/', '\' -eq $repo) { continue }
  "worktree $path [$b]"
  if (Test-Path $path) { Remove-ReparsePoints $path }
  if (-not $DryRun) {
    & git worktree remove --force $path 2>&1 | ForEach-Object { "  $_" }
    if (-not (Test-Path $guard)) { throw "GUARD FILE GONE after removing $path" }
    if (Test-Path $path) {
      $n = @(Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue).Count
      "  still on disk ($n entries) - probably held by a live session; leave it"
    } else { "  removed" }
  }
}
if (-not $DryRun) { & git worktree prune }

foreach ($b in $merged) {
  if ($b -eq (& git branch --show-current)) { continue }
  if (-not $DryRun) { & git branch -d $b 2>&1 | ForEach-Object { "  $_" } } else { "would delete branch $b" }
}

# per-branch cargo target dirs left behind by the branches just removed
foreach ($t in $ExtraTargets) {
  if (-not (Test-Path $t)) { "SKIP (absent) $t"; continue }
  $item = Get-Item $t -Force
  if ($item.LinkType) { throw "refusing to recurse into a reparse point: $t" }
  $size = Dir-Size $t
  "DELETE target {0,8:N2} GB  {1}" -f ($size / 1GB), $t
  if (-not $DryRun) { Clear-ReadOnly $t; [System.IO.Directory]::Delete($t, $true) }
}

# empty shells under .claude\worktrees that are no longer registered
$registered = @($wts.Keys | ForEach-Object { ($_ -replace '/', '\').ToLowerInvariant() })
$shellRoot = Join-Path $repo ".claude\worktrees"
if (Test-Path $shellRoot) {
  foreach ($d in Get-ChildItem $shellRoot -Directory -Force) {
    if ($registered -contains $d.FullName.ToLowerInvariant()) { continue }
    $entries = @(Get-ChildItem $d.FullName -Recurse -Force -ErrorAction SilentlyContinue)
    if ($entries.Count -eq 0) {
      "empty shell: $($d.FullName)"
      if (-not $DryRun) { try { [System.IO.Directory]::Delete($d.FullName, $false); "  removed" } catch { "  cannot remove: $($_.Exception.Message)" } }
    } else {
      "unregistered but not empty ($($entries.Count) entries): $($d.FullName)"
    }
  }
}
if (-not (Test-Path $guard)) { throw "GUARD FILE GONE at end" }
"vendor\upstream entries now: $(@(Get-ChildItem (Join-Path $repo 'vendor\upstream') -Force).Count) (was $upstreamCount)"
"---- git worktree list"
& git worktree list
"---- branches"
& git branch
exit 0
