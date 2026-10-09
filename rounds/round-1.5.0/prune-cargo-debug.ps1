# Adapted from rounds/round-1.4.8/prune-cargo-debug.ps1.
# Use Cargo's current artifact hashes, not timestamps. Only this release's debug
# cache is pruned; the fresh cargokit cache and other projects remain untouched.
param(
    [switch]$DryRun,
    [string]$CargoTargetDir = "D:\cargo-target\AcpAgentClient-1.5.0"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$target = [IO.Path]::GetFullPath($CargoTargetDir).TrimEnd('\')
if ($target -ne "D:\cargo-target\AcpAgentClient-1.5.0") { throw "Unexpected release target; refusing to prune" }
if (@(Get-Process cargo,rustc,dart,link,cl,msbuild -ErrorAction SilentlyContinue).Count) {
    throw "A compiler is running; refusing to prune"
}
$env:CARGO_TARGET_DIR = $target
$hashes = New-Object 'System.Collections.Generic.HashSet[string]'

function Run-Cargo([string[]]$CommandArgs) {
    # PowerShell 5.1 converts native stderr progress into error records.
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = @(& cargo @CommandArgs 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $saved }
    if ($code -ne 0) { throw "cargo $($CommandArgs -join ' ') failed ($code)" }
    return ,$out
}

function Collect([string[]]$Lines) {
    foreach ($line in $Lines) {
        if (-not $line.StartsWith("{")) { continue }
        try { $m = $line | ConvertFrom-Json } catch { continue }
        $paths = @()
        if ($m.reason -eq "compiler-artifact") { $paths += $m.filenames }
        elseif ($m.reason -eq "build-script-executed") { $paths += $m.out_dir }
        foreach ($p in $paths) {
            foreach ($match in [regex]::Matches([string]$p, '-([0-9a-f]{16})(\.|\\|/|$)')) {
                [void]$hashes.Add($match.Groups[1].Value)
            }
        }
    }
}

function Remove-GeneratedDirectory([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    $links = @(Get-ChildItem $Path -Recurse -Force | Where-Object {
        $_.Attributes -band [IO.FileAttributes]::ReparsePoint
    })
    if ($links.Count -or ((Get-Item $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Reparse point under $Path; refusing recursive deletion"
    }
    Get-ChildItem $Path -Recurse -File -Force | ForEach-Object { $_.IsReadOnly = $false }
    [IO.Directory]::Delete($Path, $true)
}

Push-Location (Join-Path $root "rust")
try {
    $commands = @(
        @("build", "--workspace", "--locked", "--message-format=json"),
        @("test", "--workspace", "--locked", "--no-run", "--message-format=json"),
        @("clippy", "--workspace", "--all-targets", "--locked", "--message-format=json", "--", "-D", "warnings")
    )
    foreach ($command in $commands) { Collect (Run-Cargo $command) }
    if ($hashes.Count -lt 100) { throw "Suspiciously few artifact hashes; refusing to prune" }
    Write-Output ("In-use hashes: " + $hashes.Count)
    $freed = 0L
    $files = 0
    $dirs = 0
    foreach ($f in Get-ChildItem (Join-Path $target "debug\deps") -File -Force) {
        if ($f.Name -notmatch '-([0-9a-f]{16})(\.|$)' -or $hashes.Contains($Matches[1])) { continue }
        $freed += $f.Length
        $files++
        if (-not $DryRun) { [IO.File]::Delete($f.FullName) }
    }
    foreach ($d in Get-ChildItem (Join-Path $target "debug\build") -Directory -Force) {
        if ($d.Name -notmatch '-([0-9a-f]{16})$' -or $hashes.Contains($Matches[1])) { continue }
        $freed += [long](Get-ChildItem $d.FullName -Recurse -File -Force | Measure-Object Length -Sum).Sum
        $dirs++
        if (-not $DryRun) { Remove-GeneratedDirectory $d.FullName }
    }
    $inc = Join-Path $target "debug\incremental"
    if (Test-Path $inc) {
        $freed += [long](Get-ChildItem $inc -Recurse -File -Force | Measure-Object Length -Sum).Sum
        if (-not $DryRun) { Remove-GeneratedDirectory $inc }
    }
    Write-Output ("Delete candidates: {0} deps files, {1} build dirs, incremental; {2} bytes ({3:N2} GiB)" -f $files,$dirs,$freed,($freed/1GB))
    if ($DryRun) { Write-Output "Dry run; nothing deleted"; return }
    foreach ($command in $commands) {
        $lines = Run-Cargo $command
        $stale = 0
        foreach ($line in $lines) {
            if (-not $line.StartsWith("{")) { continue }
            try { $m = $line | ConvertFrom-Json } catch { continue }
            if ($m.reason -eq "compiler-artifact" -and -not $m.fresh) { $stale++ }
        }
        Write-Output ("Freshness check {0}: {1} rebuilt units" -f $command[0],$stale)
        if ($stale) { throw "Pruning invalidated $stale compiler artifacts" }
    }
} finally {
    Pop-Location
}
