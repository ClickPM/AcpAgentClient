# Populate or verify vendor/upstream/ from pins/upstream.json (Windows PowerShell 5.1+).
#   powershell -File scripts/fetch-upstream.ps1          fetch missing repos at their pinned commit, verify existing ones
#   powershell -File scripts/fetch-upstream.ps1 -Check   verify only (exit 1 on any missing or drifted repo)
param([switch]$Check)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$pins = Get-Content (Join-Path $root "pins/upstream.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$dest = Join-Path $root "vendor/upstream"
New-Item -ItemType Directory -Force $dest | Out-Null
$fail = $false
foreach ($u in $pins.upstream) {
  $dir = Join-Path $dest $u.name
  $short = $u.commit.Substring(0, 12)
  if (Test-Path (Join-Path $dir ".git")) {
    $head = (& git -C $dir rev-parse HEAD).Trim()
    if ($head -eq $u.commit) { Write-Host "OK      $($u.name) @ $short" }
    else { Write-Host "DRIFT   $($u.name): HEAD $($head.Substring(0,12)) != pinned $short"; $fail = $true }
  } elseif ($Check) {
    Write-Host "MISSING $($u.name)"; $fail = $true
  } else {
    Write-Host "FETCH   $($u.name) @ $short ..."
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    New-Item -ItemType Directory -Force $dir | Out-Null
    & git -C $dir init -q
    & git -C $dir remote add origin $u.url
    & git -C $dir fetch -q --depth 1 origin $u.commit
    if ($LASTEXITCODE -ne 0) { throw "fetch failed for $($u.name)" }
    & git -C $dir -c advice.detachedHead=false checkout -q FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw "checkout failed for $($u.name)" }
    Write-Host "DONE    $($u.name)"
  }
}
if ($fail) { exit 1 } else { exit 0 }
