# Quality round: build the product exe (+ smoke with isolated APPDATA), build the headless exe (-t lib/main_headless.dart),
# keep a copy of each, then run the clipboard probe script against them.
$ErrorActionPreference = "Stop"
$repo = "D:\variFlight_work\AcpAgentClient-quality"
$q = "D:\cargo-target\AcpAgentClient\quality"
$env:CARGO_TARGET_DIR = "D:\cargo-target\AcpAgentClient"
Set-Location $repo

Write-Host "== product build"
& powershell -NoProfile -File scripts\build.ps1
if ($LASTEXITCODE -ne 0) { throw "product build failed ($LASTEXITCODE)" }
$out = Join-Path $repo "build\windows\x64\runner\Release"
$product = Join-Path $q "product"
if (Test-Path $product) { cmd /c rd /s /q "$product" }
Copy-Item -Recurse $out $product

Write-Host "== smoke on the product copy (isolated APPDATA)"
$report = Join-Path $q "smoke-report.json"
if (Test-Path $report) { Remove-Item $report -Force }
$savedAppData = $env:APPDATA
$env:APPDATA = Join-Path $q "appdata-smoke"
New-Item -ItemType Directory -Force $env:APPDATA | Out-Null
$env:ACP_SMOKE_REPORT = $report
try {
    $p = Start-Process -FilePath (Join-Path $product "acp_agent_client.exe") -WorkingDirectory $product -Wait -PassThru -WindowStyle Hidden
} finally {
    Remove-Item Env:\ACP_SMOKE_REPORT -ErrorAction SilentlyContinue
    $env:APPDATA = $savedAppData
}
Write-Host ("== smoke exit=" + $p.ExitCode)
Get-Content $report -Raw -Encoding UTF8 | Write-Host
if ($p.ExitCode -ne 0) { throw "smoke failed" }

Write-Host "== headless build (-t lib/main_headless.dart)"
& flutter build windows --release -t lib/main_headless.dart
if ($LASTEXITCODE -ne 0) { throw "headless build failed ($LASTEXITCODE)" }
$headless = Join-Path $q "headless"
if (Test-Path $headless) { cmd /c rd /s /q "$headless" }
Copy-Item -Recurse $out $headless
Write-Host ("product exe " + (Get-Item (Join-Path $product "acp_agent_client.exe")).Length + " bytes; headless exe " + (Get-Item (Join-Path $headless "acp_agent_client.exe")).Length + " bytes")

Write-Host "== clipboard probe"
& pwsh -STA -NoProfile -File (Join-Path $q "clip-test.ps1") -HeadlessExe (Join-Path $headless "acp_agent_client.exe") -ProductExe (Join-Path $product "acp_agent_client.exe")
Write-Host ("== clip-test exit=" + $LASTEXITCODE)
