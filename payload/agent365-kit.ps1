<#
.SYNOPSIS
    Agent 365 Onboarding Kit -- prerequisite check and per-CLI activation steps.

.DESCRIPTION
    Run this from the root of your agent project after extracting the kit into it.
    The script does not onboard anything itself -- the skills do that. It:

      1. Confirms the kit extracted to the right place.
      2. Warns if you are in an elevated shell (a common cause of "command not found").
      3. Checks prerequisites and prints the install command for anything missing.
      4. Detects which agentic CLIs you have installed.
      5. Prints the exact steps to load the skills in each one.

    The skills work with any CLI that reads one of these locations:
      .claude/skills/    Claude Code
      .agents/skills/    VS Code agent mode, Copilot cloud agent, gh skill
      .github/           GitHub Copilot CLI, VS Code Copilot Chat

.PARAMETER DoctorOnly
    Run the prerequisite check and exit, without printing activation steps.

.PARAMETER SkipDoctor
    Skip the prerequisite check and go straight to the activation steps.

.PARAMETER WireCopilot
    Create or append the Agent 365 skill instructions to .github/copilot-instructions.md.
    Never overwrites an existing file -- appends to it, once.

.PARAMETER WireClaudeHook
    Add the optional SessionStart upstream-version notice to .claude/settings.json.
    Skipped automatically if that file already exists.

.PARAMETER Launch
    Which CLI to launch once the checks pass. Currently supports 'claude'.

.EXAMPLE
    .\agent365-kit.ps1

.EXAMPLE
    .\agent365-kit.ps1 -WireCopilot

.EXAMPLE
    .\agent365-kit.ps1 -Launch claude
#>
[CmdletBinding()]
param(
    [switch] $DoctorOnly,
    [switch] $SkipDoctor,
    [switch] $WireCopilot,
    [switch] $WireClaudeHook,
    [ValidateSet('claude')]
    [string] $Launch
)

$ErrorActionPreference = 'Stop'

$TRIGGER = 'Onboard this agent to Agent 365.'

function Write-Head { param([string] $T) Write-Host ''; Write-Host $T -ForegroundColor Cyan }
function Write-Ok   { param([string] $T) Write-Host "  [ ok ] $T" -ForegroundColor Green }
function Write-Warn { param([string] $T) Write-Host "  [warn] $T" -ForegroundColor Yellow }
function Write-Err  { param([string] $T) Write-Host "  [FAIL] $T" -ForegroundColor Red }
function Write-Cmd  { param([string] $T) Write-Host "      $T" -ForegroundColor White }
function Write-Note { param([string] $T) Write-Host "  $T" -ForegroundColor Gray }

$KitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ''
Write-Host 'Agent 365 Onboarding Kit' -ForegroundColor White
Write-Host '========================' -ForegroundColor DarkGray

# -- 1. Confirm the kit landed in the right place -----------------------------

$Canonical = Join-Path $KitRoot '.a365-kit\skills\a365-setup\SKILL.md'
if (-not (Test-Path -LiteralPath $Canonical)) {
    Write-Host ''
    Write-Err 'Could not find .a365-kit\skills\a365-setup\SKILL.md next to this script.'
    Write-Host ''
    Write-Note 'Extract the kit into the ROOT of your agent project, so the kit folders sit'
    Write-Note 'alongside your agent source. Expected layout:'
    Write-Host ''
    Write-Host '      your-agent-project\'      -ForegroundColor DarkGray
    Write-Host '        .a365-kit\'             -ForegroundColor DarkGray
    Write-Host '        .claude\skills\'        -ForegroundColor DarkGray
    Write-Host '        .agents\skills\'        -ForegroundColor DarkGray
    Write-Host '        agent365-kit.ps1'       -ForegroundColor DarkGray
    Write-Host '        <your agent source>'    -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

$SkillCount = (Get-ChildItem -Path (Join-Path $KitRoot '.a365-kit\skills') -Directory).Count
Write-Host ''
Write-Ok "Kit layout looks correct ($SkillCount skills)"

if ((Get-Location).Path -ne $KitRoot) {
    Write-Warn "Switching working directory to the project root: $KitRoot"
    Set-Location -LiteralPath $KitRoot
}

# -- 2. Elevated-shell check --------------------------------------------------
# Claude Code, gh, and dotnet global tools install per-user. In an elevated shell
# the per-user PATH entries are usually absent, so these tools look "not installed"
# when they are simply not on the Administrator PATH.

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ''
    Write-Warn 'This is an ELEVATED (Administrator) PowerShell session.'
    Write-Host ''
    Write-Host '  Claude Code, gh, and the a365 CLI install per-user, so they are usually NOT'  -ForegroundColor Yellow
    Write-Host '  on the Administrator PATH. Tools that ARE installed will look missing, and'   -ForegroundColor Yellow
    Write-Host '  onboarding will fail with "command not found".'                               -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Close this window and re-run in a NORMAL (non-elevated) PowerShell.'          -ForegroundColor Yellow
    Write-Host ''
    $answer = Read-Host '  Continue anyway? [y/N]'
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host ''
        Write-Note 'Stopped. Re-run from a non-elevated shell.'
        Write-Host ''
        exit 1
    }
}

# -- 3. Prerequisites ---------------------------------------------------------

if (-not $SkipDoctor) {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Host ''
        Write-Err 'Node.js is not installed (or not on PATH).'
        Write-Host ''
        Write-Note 'Node.js runs the prerequisite check and the skill validators. Install it:'
        Write-Host ''
        Write-Cmd 'winget install --id OpenJS.NodeJS.LTS -e'
        Write-Host ''
        Write-Note 'Then open a NEW terminal and re-run this script.'
        Write-Host ''
        exit 1
    }

    & node (Join-Path $KitRoot '.a365-kit\doctor.js')
    if ($LASTEXITCODE -ne 0) {
        Write-Note 'Install the missing prerequisites above, then re-run this script.'
        Write-Note '(Open a NEW terminal afterwards so PATH changes take effect.)'
        Write-Host ''
        exit 1
    }
}

if ($DoctorOnly) {
    Write-Note 'Prerequisite check complete. Re-run without -DoctorOnly for activation steps.'
    Write-Host ''
    exit 0
}

# -- 4. Optional wiring -------------------------------------------------------

if ($WireCopilot) {
    Write-Head 'Wiring GitHub Copilot instructions'
    $src = Join-Path $KitRoot '.a365-kit\copilot-instructions.md'
    $dstDir = Join-Path $KitRoot '.github'
    $dst = Join-Path $dstDir 'copilot-instructions.md'

    if (-not (Test-Path -LiteralPath $src)) {
        Write-Err 'Missing .a365-kit\copilot-instructions.md -- kit may be incomplete.'
    }
    else {
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        if (-not (Test-Path -LiteralPath $dst)) {
            Copy-Item -LiteralPath $src -Destination $dst
            Write-Ok 'Created .github\copilot-instructions.md'
        }
        elseif ((Get-Content -LiteralPath $dst -Raw) -match 'Agent 365 Skills') {
            Write-Ok 'Already wired -- .github\copilot-instructions.md mentions Agent 365.'
        }
        else {
            # Append rather than overwrite: this file is commonly project-owned.
            Add-Content -LiteralPath $dst -Value "`n`n---`n"
            Add-Content -LiteralPath $dst -Value (Get-Content -LiteralPath $src -Raw)
            Write-Ok 'Appended Agent 365 instructions to your existing .github\copilot-instructions.md'
        }
    }
}

if ($WireClaudeHook) {
    Write-Head 'Wiring the optional upstream-version notice'
    $fragment = Join-Path $KitRoot '.a365-kit\settings-fragment.json'
    $settings = Join-Path $KitRoot '.claude\settings.json'
    if (Test-Path -LiteralPath $settings) {
        Write-Warn 'This project already has .claude\settings.json -- leaving it untouched.'
        Write-Note 'Merge the "hooks" block from .a365-kit\settings-fragment.json by hand.'
    }
    else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settings) | Out-Null
        Copy-Item -LiteralPath $fragment -Destination $settings
        Write-Ok 'Created .claude\settings.json'
    }
}

# -- 5. Detect CLIs and print activation steps --------------------------------

function Test-Cli { param([string] $Probe)
    try {
        Invoke-Expression $Probe 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

$hasClaude   = [bool](Get-Command claude -ErrorAction SilentlyContinue)
$hasGh       = [bool](Get-Command gh -ErrorAction SilentlyContinue)
$hasCode     = [bool](Get-Command code -ErrorAction SilentlyContinue)
$hasGhSkill  = $false
$hasGhCopilot = $false
if ($hasGh) {
    $hasGhSkill   = Test-Cli 'gh skill --version'
    $hasGhCopilot = Test-Cli 'gh copilot --version'
}

Write-Head 'Detected CLIs'
if ($hasClaude)    { Write-Ok 'Claude Code' }         else { Write-Note '  --   Claude Code (not installed)' }
if ($hasGhSkill)   { Write-Ok 'gh skill' }            else { Write-Note '  --   gh skill (not installed)' }
if ($hasGhCopilot) { Write-Ok 'GitHub Copilot CLI' }  else { Write-Note '  --   GitHub Copilot CLI (not installed)' }
if ($hasCode)      { Write-Ok 'VS Code' }             else { Write-Note '  --   VS Code (not installed)' }

Write-Head 'How to start onboarding'
Write-Host ''
Write-Note 'The skills are already in place. Pick your CLI:'
Write-Host ''

Write-Host '  Claude Code' -ForegroundColor White
Write-Note '    Project skills in .claude/skills/ load automatically. From this folder:'
Write-Cmd 'claude'
Write-Note '    then type:'
Write-Cmd "`"$TRIGGER`""
Write-Host ''

Write-Host '  VS Code agent mode / Copilot cloud agent' -ForegroundColor White
Write-Note '    Skills in .agents/skills/ are picked up automatically. Open this folder in'
Write-Note '    VS Code, switch Copilot Chat to Agent mode, confirm with /skills list, then ask:'
Write-Cmd "`"$TRIGGER`""
Write-Host ''

Write-Host '  GitHub Copilot CLI' -ForegroundColor White
Write-Note '    Copilot reads .github/copilot-instructions.md. Wire it once:'
Write-Cmd '.\agent365-kit.ps1 -WireCopilot'
Write-Note '    then, from this folder:'
Write-Cmd "gh copilot suggest `"$TRIGGER`""
Write-Host ''

Write-Host '  Any other agentic CLI' -ForegroundColor White
Write-Note '    Point it at .a365-kit/skills/a365-setup/SKILL.md and tell it to follow that file.'
Write-Note '    The skills are plain Markdown -- nothing is Claude-specific except the'
Write-Note '    validator hooks, which are optional.'
Write-Host ''

Write-Host '  ---' -ForegroundColor DarkGray
Write-Note 'a365-setup is the entry point. It checks prerequisites, asks which capabilities'
Write-Note 'you want, then hands off to make-ai-teammate or make-a365-agent.'
Write-Host ''

# -- 6. Optional launch -------------------------------------------------------

if ($Launch -eq 'claude') {
    if (-not $hasClaude) {
        Write-Err 'Claude Code CLI not found on PATH.'
        Write-Note 'Install it with:  npm install -g @anthropic-ai/claude-code'
        Write-Host ''
        exit 1
    }
    Write-Head 'Launching Claude Code'
    Write-Host ''
    & claude $TRIGGER
    exit $LASTEXITCODE
}
