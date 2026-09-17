# design/brand/app-icon.svg -> windows/runner/resources/app_icon.ico（多尺寸，每帧 PNG 压缩）。
# 改了 app-icon.svg 之后跑一次；应用内标记是 lib/ui/shell/app_logo.dart 里按同一几何拼的，不由本脚本生成。
#
#   powershell -File scripts/render-icon.ps1
#
# 渲染用 headless Chromium（Edge 或 Chrome），与 scripts/render-design.ps1 同一条路子；
# --default-background-color=00000000 让底板圆角外透明，否则深色任务栏上会露白角。
param(
    [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256)
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$svg = Join-Path $root "design\brand\app-icon.svg"
$ico = Join-Path $root "windows\runner\resources\app_icon.ico"
if (-not (Test-Path $svg)) { throw "source svg not found: $svg" }

$browser = @(
    "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw "No Chromium browser found (Edge or Chrome)." }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("acp-icon-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    Copy-Item $svg (Join-Path $work "app-icon.svg")
    $frames = @()
    foreach ($s in ($Sizes | Sort-Object)) {
        $html = Join-Path $work ("f" + $s + ".html")
        $png = Join-Path $work ("f" + $s + ".png")
        $body = '<!doctype html><meta charset="utf-8"><style>html,body{margin:0;padding:0;background:transparent}' +
                'img{display:block;width:' + $s + 'px;height:' + $s + 'px}</style><img src="app-icon.svg">'
        [System.IO.File]::WriteAllText($html, $body, (New-Object System.Text.UTF8Encoding($false)))
        $url = "file:///" + ($html -replace '\\', '/')
        $argList = @(
            "--headless=new", "--disable-gpu", "--hide-scrollbars",
            "--default-background-color=00000000",
            ("--window-size=" + $s + "," + $s),
            ('--screenshot="' + $png + '"'),
            ('"' + $url + '"')
        )
        $p = Start-Process -FilePath $browser -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
        if (-not (Test-Path $png)) { throw ("render failed (exit " + $p.ExitCode + ") at size " + $s) }
        $frames += [pscustomobject]@{ Size = $s; Bytes = [System.IO.File]::ReadAllBytes($png) }
    }

    # ICONDIR(6) + ICONDIRENTRY(16) * N + 各帧 PNG 原样拼接。256 的宽高字节写 0。
    $fs = [System.IO.File]::Create($ico)
    try {
        $w = New-Object System.IO.BinaryWriter($fs)
        $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$frames.Count)
        $offset = 6 + 16 * $frames.Count
        foreach ($f in $frames) {
            $dim = $f.Size
            if ($dim -ge 256) { $dim = 0 }
            $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
            $w.Write([uint16]1); $w.Write([uint16]32)
            $w.Write([uint32]$f.Bytes.Length); $w.Write([uint32]$offset)
            $offset += $f.Bytes.Length
        }
        foreach ($f in $frames) { $w.Write($f.Bytes) }
        $w.Flush()
    } finally { $fs.Dispose() }
} finally {
    Remove-Item $work -Recurse -Force
}
Write-Host ("wrote " + $ico + " (" + ($Sizes -join ", ") + ")")
