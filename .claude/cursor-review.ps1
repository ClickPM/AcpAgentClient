param(
  [string]$Base = "main",
  [ValidateSet("branch", "since", "worktree")]
  [string]$Scope = "branch",
  [ValidateSet("review", "adversarial")]
  [string]$Kind = "review",
  [string]$Model = "cursor-grok-4.6-high",
  [string]$Note = "",
  [switch]$Wait
)

# cursor CLI 独立审查的启动脚本(所有者裁定 2026-09-10:codex 被限流,审查切到 cursor CLI + grok 4.6 high)。
# 契约(职责边界 / 判据 / 严重级 / 输出格式)在同目录的 cursor-review-prompt.md;流程与坑在 docs/review-workflow.md。
#
# 用法(在仓库根跑):
#   powershell -File .claude/cursor-review.ps1                      # 前两轮:全量分支 diff(main...HEAD),后台跑
#   powershell -File .claude/cursor-review.ps1 -Scope since -Base <上一轮已审提交>   # 第 3 轮起:只审整改 diff
#   powershell -File .claude/cursor-review.ps1 -Scope worktree      # 未提交的改动(零已提交基线时)
#   powershell -File .claude/cursor-review.ps1 -Kind adversarial    # 质疑设计取舍那一档
#   powershell -File .claude/cursor-review.ps1 -Wait                # 前台跑(小 diff 时省事,会阻塞)
#
# 【为什么默认后台 + Start-Process】审查要 6–15 分钟,而经 Claude 的后台 Bash 起会随 launcher 一起死
# (2026-09-04 实测:38 分钟零日志)。Start-Process 脱离工具生命周期,结果落 .out 文件。
# 【等待期间不要改仓库里的文件】审查器是实时读工作树的,改了它读到的就是半新半旧的代码、findings 对不上提交。

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot

# cursor-agent 在 Windows 上装在 %LOCALAPPDATA%/cursor-agent/(不在 PATH 上,所以先按绝对路径找)
$agent = Join-Path (Join-Path $env:LOCALAPPDATA "cursor-agent") "cursor-agent.cmd"
if (-not (Test-Path $agent)) {
  $found = Get-Command "cursor-agent" -ErrorAction SilentlyContinue
  if ($null -eq $found) {
    throw "找不到 cursor-agent(期望 %LOCALAPPDATA%/cursor-agent/cursor-agent.cmd 或 PATH 上);先装 Cursor CLI 并 cursor-agent login"
  }
  $agent = $found.Source
}

# 登录态先验:未登录时 cursor-agent 会等交互输入,后台跑就是永远不结束
$who = & $agent status
if ($LASTEXITCODE -ne 0 -or -not ($who -match "Logged in")) {
  throw "cursor-agent 未登录:先在终端里跑 cursor-agent login"
}

if ($Scope -eq "branch") { $range = "$Base...HEAD" }
elseif ($Scope -eq "since") { $range = "$Base..HEAD" }
else { $range = "HEAD" }   # worktree:未提交的改动(零已提交基线的轮次用这一档)

Push-Location $repo
try {
  if ($Scope -ne "worktree") {
    & git rev-parse --verify --quiet $Base | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git 里没有这个基准:$Base" }
  }
  $stat = & git diff --stat $range
  if ([string]::IsNullOrWhiteSpace(($stat -join ""))) {
    throw "范围 $range 是空 diff,没什么可审的(基准或 scope 填错了?)"
  }
  $dirty = & git status --porcelain
  if (-not [string]::IsNullOrWhiteSpace(($dirty -join ""))) {
    Write-Output "! 工作区不干净:审查器读的是工作树的当前内容,未提交的改动会一起被看到"
  }
}
finally { Pop-Location }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$dir = Join-Path (Join-Path $repo ".claude") "reviews"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$tpl = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot "cursor-review-prompt.md")
if ($Kind -eq "review") {
  # 只有 adversarial 档保留「质疑取舍」那一段
  $tpl = [regex]::Replace($tpl, "(?s)<!-- ADVERSARIAL-ONLY-START -->.*?<!-- ADVERSARIAL-ONLY-END -->\s*", "")
}
if ([string]::IsNullOrWhiteSpace($Note)) { $noteText = "无" } else { $noteText = $Note }
$tpl = $tpl.Replace("{{RANGE}}", $range).Replace("{{NOTE}}", $noteText)

$rel = ".claude/reviews/$stamp-$Kind.prompt.md"
$promptFile = Join-Path $dir "$stamp-$Kind.prompt.md"
$outFile = Join-Path $dir "$stamp-$Kind.out.md"
$errFile = Join-Path $dir "$stamp-$Kind.err.log"
# PowerShell 5.1 的 Set-Content 默认按 ANSI 写,中文会乱码 —— 必须显式 utf8
Set-Content -Path $promptFile -Value $tpl -Encoding utf8

$ask = "严格执行 $rel 里的审查任务书,不要修改任何文件。"
$cmdline = "-p ""$ask"" --model $Model --plan --force --trust --output-format text"

Write-Output "范围: $range   档: $Kind   模型: $Model"
Write-Output "任务书: $promptFile"

if ($Wait) {
  Push-Location $repo
  try { & $agent -p $ask --model $Model --plan --force --trust --output-format text | Tee-Object -FilePath $outFile }
  finally { Pop-Location }
  Write-Output "结果: $outFile"
  exit 0
}

$startArgs = @{ FilePath = $agent; ArgumentList = $cmdline; WorkingDirectory = $repo; RedirectStandardOutput = $outFile; RedirectStandardError = $errFile; WindowStyle = "Hidden"; PassThru = $true }
$proc = Start-Process @startArgs
Write-Output "已在后台启动: pid=$($proc.Id)"
Write-Output "结果(结束时一次性落地): $outFile"
Write-Output "心跳(推理摘要与命令行): $errFile"
Write-Output "等结束: 轮询 .out 非空,或 tasklist /FI (PID eq $($proc.Id)) —— Git Bash 里先 export MSYS_NO_PATHCONV=1"
Write-Output "等待期间不要改仓库里的文件"
