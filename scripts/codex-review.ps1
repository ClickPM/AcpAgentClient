# Owner-selected review runner. Does not change the default Cursor workflow.
# powershell -NoProfile -File scripts/codex-review.ps1 -Scope worktree
# powershell -NoProfile -File scripts/codex-review.ps1 -Scope since -Base <sha>
# Runs synchronously, read-only. Model/effort/speed are fixed for this assignment.
param(
    [ValidateSet("worktree", "since")]
    [string]$Scope = "worktree",
    [string]$Base,
    [string]$Note = ""
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$codex = (Get-Command codex.cmd -ErrorAction Stop).Source
$utf8 = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $utf8
[Console]::OutputEncoding = $utf8

Push-Location $root
try {
    if ($Scope -eq "since") {
        if (-not $Base) { throw "-Base is required for -Scope since" }
        $sha = & git rev-parse --verify "$Base^{commit}"
        if ($LASTEXITCODE -ne 0) { throw "Invalid base commit: $Base" }
        $range = "$($sha.Trim())..HEAD"
        $changes = & git diff --name-only $range
    } else {
        $range = "HEAD"
        $changes = & git status --porcelain
    }
    if ($LASTEXITCODE -ne 0) { throw "Failed to inspect review range" }
    if (-not $changes) { throw "Empty review range" }

    $template = Join-Path $root ".claude\cursor-review-prompt.md"
    $prompt = [IO.File]::ReadAllText($template, $utf8)
    $prompt = [regex]::Replace($prompt, '(?s)<!-- ADVERSARIAL-ONLY-START -->.*?<!-- ADVERSARIAL-ONLY-END -->', '')
    $prompt = $prompt.Replace('{{RANGE}}', $range).Replace('{{NOTE}}', $Note)
    $prompt += "`nOwner explicitly selected Codex CLI for this review; do not invoke Cursor or delegate to other agents."

    $outDir = Join-Path $root ".claude\reviews"
    New-Item -ItemType Directory -Force $outDir | Out-Null
    $stem = Join-Path $outDir ((Get-Date -Format "yyyyMMdd-HHmmss") + "-codex-review")
    [IO.File]::WriteAllText("$stem.prompt.md", $prompt, $utf8)
    Write-Host "Range: $range"
    Write-Host "Model: gpt-6.1-sol; reasoning: medium; fast mode: off"
    Write-Host "Result: $stem.out.md"

    # Ignore user config only for this invocation: no inherited fast service tier,
    # MCP servers, hooks or alternate provider. Authentication is still inherited.
    # The custom review prompt supplies the exact range; target flags conflict with
    # custom prompts in some CLI versions, so do not also pass --base/--uncommitted.
    # Windows PowerShell 5.1 treats native stderr progress as error records.
    # Capture it without terminating a healthy process; use the exit code instead.
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $prompt | & $codex exec review --ignore-user-config --ephemeral `
            --model gpt-6.1-sol -c 'review_model="gpt-6.1-sol"' `
            -c 'model_reasoning_effort="medium"' `
            -c 'sandbox_mode="read-only"' -c 'approval_policy="never"' `
            --disable fast_mode --output-last-message "$stem.out.md" - `
            1> "$stem.stdout.log" 2> "$stem.err.log"
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    [IO.File]::WriteAllText("$stem.exit-code.txt", [string]$code, $utf8)
    if ($code -ne 0) {
        throw "Codex review exited $code; inspect $stem.err.log"
    }
    if (-not (Test-Path "$stem.out.md") -or (Get-Item "$stem.out.md").Length -eq 0) {
        throw "Codex review produced no final result; inspect $stem.stdout.log and $stem.err.log"
    }
    Get-Content "$stem.out.md" -Raw -Encoding UTF8
} finally {
    Pop-Location
}
