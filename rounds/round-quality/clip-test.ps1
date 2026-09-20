# Windows clipboard probe runner (rule 9 evidence for the quality round).
#   pwsh -STA -File clip-test.ps1 -HeadlessExe <acp_agent_client.exe built with -t lib/main_headless.dart> -ProductExe <product exe>
# Steps: (A) bitmap on the clipboard -> probe; (B) file drop list with a CJK-named PNG + a .txt -> probe;
#        (C) plain text -> probe (must be empty); (D) product exe ignores ACP_R3_REPORT (window stays up).
param(
    [Parameter(Mandatory = $true)][string]$HeadlessExe,
    [Parameter(Mandatory = $true)][string]$ProductExe
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$scratch = "D:\cargo-target\AcpAgentClient\quality\run"
New-Item -ItemType Directory -Force $scratch | Out-Null

function Invoke-Probe([string]$label) {
    $report = Join-Path $scratch ("probe-" + $label + ".json")
    if (Test-Path $report) { Remove-Item $report -Force }
    $env:ACP_CLIPBOARD_PROBE = $report
    try {
        $p = Start-Process -FilePath $HeadlessExe -WorkingDirectory (Split-Path -Parent $HeadlessExe) -PassThru -WindowStyle Hidden
        if (-not $p.WaitForExit(60000)) { & taskkill /T /F /PID $p.Id | Out-Null; throw "probe $label timed out" }
    } finally {
        Remove-Item Env:\ACP_CLIPBOARD_PROBE -ErrorAction SilentlyContinue
    }
    Write-Host ("== probe " + $label + " exit=" + $p.ExitCode)
    Get-Content $report -Raw -Encoding UTF8 | Write-Host
}

# (A) 64x48 bitmap: top-left pixel red, everything else blue (opaque).
$bmp = New-Object System.Drawing.Bitmap 64, 48
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::Blue)
$g.Dispose()
$bmp.SetPixel(0, 0, [System.Drawing.Color]::Red)
[System.Windows.Forms.Clipboard]::SetImage($bmp)
Write-Host "clipboard: bitmap 64x48 (top-left red, rest blue), ContainsImage=" ([System.Windows.Forms.Clipboard]::ContainsImage())
Invoke-Probe "bitmap"

# (B) file drop list: a CJK-named PNG (real PNG bytes) + a text file that must be ignored.
$cjk = [string]::Join("", @([char]0x622A, [char]0x56FE, [char]0x0020, [char]0x6D4B, [char]0x8BD5))   # "截图 测试"
$pngPath = Join-Path $scratch ($cjk + ".png")
$bmp.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
$txtPath = Join-Path $scratch "notes.txt"
Set-Content -Path $txtPath -Value "not an image" -Encoding UTF8
$files = New-Object System.Collections.Specialized.StringCollection
[void]$files.Add($pngPath)
[void]$files.Add($txtPath)
[System.Windows.Forms.Clipboard]::SetFileDropList($files)
Write-Host ("clipboard: file drop list [" + $pngPath + ", " + $txtPath + "] size=" + (Get-Item $pngPath).Length)
Invoke-Probe "files"

# (C) plain text only: no images, ok=true.
[System.Windows.Forms.Clipboard]::SetText("hello from clip-test")
Invoke-Probe "text"
$bmp.Dispose()

# (D) the product exe must NOT go headless on ACP_R3_REPORT: it should still show a window after 6 s.
$r3 = Join-Path $scratch "r3-should-not-exist.json"
if (Test-Path $r3) { Remove-Item $r3 -Force }
$env:ACP_R3_REPORT = $r3
$env:APPDATA = Join-Path $scratch "appdata"
New-Item -ItemType Directory -Force $env:APPDATA | Out-Null
try {
    $p = Start-Process -FilePath $ProductExe -WorkingDirectory (Split-Path -Parent $ProductExe) -PassThru
    Start-Sleep -Seconds 6
    $alive = -not $p.HasExited
    $p.Refresh()
    $hwnd = $p.MainWindowHandle
    Write-Host ("== product exe with ACP_R3_REPORT set: alive=" + $alive + " mainWindow=" + $hwnd + " reportWritten=" + (Test-Path $r3))
    if ($alive) { & taskkill /T /F /PID $p.Id | Out-Null }
    # and the headless build DOES take the same variable (no agent configured for the id -> fails fast with a report).
    $env:ACP_R3_AGENT = "no-such-agent"
    $env:ACP_R3_TIMEOUT = "20"
    $env:APPDATA = Join-Path $scratch "appdata"
    New-Item -ItemType Directory -Force $env:APPDATA | Out-Null
    $p = Start-Process -FilePath $HeadlessExe -WorkingDirectory (Split-Path -Parent $HeadlessExe) -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(90000)) { & taskkill /T /F /PID $p.Id | Out-Null; Write-Host "headless r3 timed out" }
    Write-Host ("== headless exe with ACP_R3_REPORT set: exit=" + $p.ExitCode + " reportWritten=" + (Test-Path $r3))
    if (Test-Path $r3) { (Get-Content $r3 -Raw -Encoding UTF8).Substring(0, [Math]::Min(400, (Get-Item $r3).Length)) | Write-Host }
} finally {
    Remove-Item Env:\ACP_R3_REPORT, Env:\ACP_R3_AGENT, Env:\ACP_R3_TIMEOUT -ErrorAction SilentlyContinue
}
