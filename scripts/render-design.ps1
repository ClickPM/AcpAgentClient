# Render every design/<Round>/*.dc.html to a same-named PNG next to it.
# Uses a headless Chromium (Edge or Chrome) at scale 1; the PNG size is the
# artboard's own $preview size recorded in the .dc.html, so "PNG size == frame"
# holds by construction. Re-run after any change to a .dc.html.
#
#   powershell -File scripts/render-design.ps1                # round-design
#   powershell -File scripts/render-design.ps1 -Round round-02
#   powershell -File scripts/render-design.ps1 -Only 01,25    # subset by number prefix
param(
    [string]$Round = "round-design",
    [string[]]$Only = @()
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root ("design\" + $Round)
if (-not (Test-Path $dir)) { throw "design round dir not found: $dir" }

$browser = @(
    "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw "No Chromium browser found (Edge or Chrome)." }

$files = Get-ChildItem $dir -Filter "*.dc.html" | Sort-Object Name
# `powershell -File ... -Only 01,25` hands the script one string "01,25"; split it so both call styles work.
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
if ($Only.Count -gt 0) {
    $files = $files | Where-Object { $n = $_.Name; ($Only | Where-Object { $n.StartsWith($_) }).Count -gt 0 }
}
if ($files.Count -eq 0) { throw "no .dc.html matched" }

foreach ($f in $files) {
    $html = Get-Content $f.FullName -Raw -Encoding UTF8
    if ($html -notmatch '\$preview&quot;:\{&quot;width&quot;:(\d+),&quot;height&quot;:(\d+)') {
        throw ("no `$preview size in " + $f.Name)
    }
    $w = [int]$Matches[1]; $h = [int]$Matches[2]
    $png = Join-Path $dir ($f.Name -replace '\.dc\.html$', '.png')
    if (Test-Path $png) { Remove-Item $png -Force }
    $url = "file:///" + ($f.FullName -replace '\\', '/')
    # Start-Process + -Wait: the browser's own stderr chatter must not be treated as a PowerShell error.
    $argList = @(
        "--headless=new", "--disable-gpu", "--hide-scrollbars",
        ("--window-size=" + $w + "," + $h),
        ('--screenshot="' + $png + '"'),
        ('"' + $url + '"')
    )
    $p = Start-Process -FilePath $browser -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
    if (-not (Test-Path $png)) { throw ("render failed (exit " + $p.ExitCode + "): " + $f.Name) }
    Write-Host ("{0,-30} {1}x{2}" -f $f.Name, $w, $h)
}
Write-Host ("rendered " + $files.Count + " artboard(s) into " + $dir)
