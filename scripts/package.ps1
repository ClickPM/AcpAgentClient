# Windows 打包（R8）：免安装 zip（含 / 不含 sidecar）与 Inno Setup 安装器（per-user、不签名）。
#   powershell -File scripts/package.ps1                 # 构建 + 三件产物
#   powershell -File scripts/package.ps1 -SkipBuild      # 直接用现有 build/windows/x64/runner/Release
#   powershell -File scripts/package.ps1 -NoInstaller    # 只出两个 zip（跳过 ISCC）
# 产物落 dist/（gitignored）：
#   dist/AcpAgentClient-<版本>-windows-x64.zip            含 sidecar
#   dist/AcpAgentClient-<版本>-windows-x64-nosidecar.zip  不含（ROUNDS R8 验收 2 要两个体积数字）
#   dist/AcpAgentClient-<版本>-setup.exe                  安装器
#
# sidecar **不在这里构建**（冷编译约 50 分钟，scripts/build-sidecar.ps1 管）：build/sidecar 里有就随包，
# 没有就只出「不含 sidecar」那个 zip 并在末尾说明 —— 缺了应用照常能跑，只是 agent 列表里没有 Zed Agent。
# 版本号只认 pubspec.yaml（应用版本的事实来源）；sidecar 的版本跟 zed 钉版本走、与这里无关，见
# scripts/validate.ps1 的「版本门」。
param(
    [switch]$SkipBuild,
    [switch]$NoInstaller,
    [string]$CargoTargetDir = "D:\cargo-target\AcpAgentClient"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

function Format-Size([long]$bytes) {
    "{0:N1} MB" -f ($bytes / 1MB)
}

# .NET 的 ZipFile 而不是 Compress-Archive：后者对 226 MB / 上千个文件的目录慢到分钟级，
# 且在 PowerShell 5.1 上对长路径与空目录有额外坑。
function New-Zip([string]$sourceDir, [string]$zipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $sourceDir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
}

Push-Location $root
try {
    $pubspec = Get-Content (Join-Path $root "pubspec.yaml") -Raw -Encoding UTF8
    if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') { throw "pubspec.yaml 里没有 version: X.Y.Z+N 行" }
    $version = $Matches[1]
    Write-Host "== packaging AcpAgent Client $version"

    if (-not $SkipBuild) {
        & (Join-Path $PSScriptRoot "build.ps1") -CargoTargetDir $CargoTargetDir
    }

    $releaseDir = Join-Path $root "build/windows/x64/runner/Release"
    $exe = Join-Path $releaseDir "acp_agent_client.exe"
    if (-not (Test-Path $exe)) { throw "没有 release 产物：$exe（先跑 scripts/build.ps1）" }

    $dist = Join-Path $root "dist"
    $stageRoot = Join-Path $dist "stage"
    $hold = Join-Path $dist "hold"
    $name = "AcpAgentClient-$version-windows-x64"
    $payload = Join-Path $stageRoot $name
    foreach ($d in @($stageRoot, $hold)) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } }
    New-Item -ItemType Directory -Force $payload | Out-Null
    New-Item -ItemType Directory -Force $hold | Out-Null

    Copy-Item (Join-Path $releaseDir "*") $payload -Recurse -Force
    # GPL-3.0-or-later：分发二进制要带许可证与派生文件清单（README「许可证」、NOTICE）。
    foreach ($f in @("LICENSE", "NOTICE")) { Copy-Item (Join-Path $root $f) (Join-Path $payload $f) -Force }

    # 先压「不含 sidecar」：把它挪到 dist/hold（stage 之外，否则会被一起压进去），压完再挪回来。
    $sidecarInPayload = Join-Path $payload "zed-agent-acp.exe"
    $hasSidecar = Test-Path $sidecarInPayload
    $sidecarHeld = Join-Path $hold "zed-agent-acp.exe"
    if ($hasSidecar) { Move-Item $sidecarInPayload $sidecarHeld -Force }

    $zipLean = Join-Path $dist "$name-nosidecar.zip"
    New-Zip $stageRoot $zipLean
    $results = @([pscustomobject]@{ Artifact = "zip (no sidecar)"; Path = $zipLean; Size = (Get-Item $zipLean).Length })

    $zipFull = $null
    if ($hasSidecar) {
        Move-Item $sidecarHeld $sidecarInPayload -Force
        $zipFull = Join-Path $dist "$name.zip"
        New-Zip $stageRoot $zipFull
        $results += [pscustomobject]@{ Artifact = "zip (with sidecar)"; Path = $zipFull; Size = (Get-Item $zipFull).Length }
    }
    Remove-Item $hold -Recurse -Force

    if (-not $NoInstaller) {
        $iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
        if (-not $iscc) {
            $candidates = @(
                "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
                "C:\Program Files\Inno Setup 6\ISCC.exe"
            )
            $iscc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        }
        if (-not $iscc) { throw "找不到 ISCC.exe（Inno Setup 6）；装它或改用 -NoInstaller" }
        Write-Host "== ISCC: $iscc"
        $iss = Join-Path $root "packaging/windows/acp-agent-client.iss"
        & $iscc "/DAppVersion=$version" "/DPayloadDir=$payload" "/O$dist" $iss | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)" }
        $setup = Join-Path $dist "AcpAgentClient-$version-setup.exe"
        if (-not (Test-Path $setup)) { throw "ISCC 没产出 $setup" }
        $results += [pscustomobject]@{ Artifact = "installer"; Path = $setup; Size = (Get-Item $setup).Length }
    }

    $payloadSize = (Get-ChildItem $payload -Recurse -File | Measure-Object -Property Length -Sum).Sum
    Write-Host ""
    Write-Host ("== payload {0} ({1})" -f $payload, (Format-Size $payloadSize))
    foreach ($r in $results) {
        Write-Host ("OK  {0,-20} {1,10}  {2}" -f $r.Artifact, (Format-Size $r.Size), $r.Path)
    }
    if (-not $hasSidecar) {
        Write-Host "NOTE  build/sidecar/zed-agent-acp.exe 不在，本次只出了不含 sidecar 的包（scripts/build-sidecar.ps1 可以补）"
    }
    # 可选字体（R7.6）随 runner 的 install 规则进了应用目录，也就进了这三件产物。它们的协议允许
    # **嵌在应用里**分发、不允许把字体文件单独发出去（所以仓库里也没有），发包前知会一声。
    $fontFiles = @(Get-ChildItem (Join-Path $payload "fonts") -File -ErrorAction SilentlyContinue)
    if ($fontFiles.Count -gt 0) {
        Write-Host ("NOTE  包里带了 {0} 个可选字体文件（assets/fonts/optional → fonts/）：随应用分发可以，单独分发字体文件不行，见 assets/fonts/optional/README.md" -f $fontFiles.Count)
    }
} finally {
    Pop-Location
}
