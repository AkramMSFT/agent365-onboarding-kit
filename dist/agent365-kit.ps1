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

.PARAMETER Update
    Replace the kit in this project with the latest release. Touches ONLY kit paths
    (.a365-kit, the kit's own skill folders under .claude/skills and .agents/skills, the
    launchers, and AGENT365-KIT-README.md). Your agent, .env, config and .claude/settings.json
    are never modified.

.PARAMETER UpdateFrom
    One-off override of where -Update fetches the kit from: a .zip path (local or file share)
    or an HTTPS URL. Without it the source is resolved, in order, from the environment
    variable A365_KIT_UPDATE_SOURCE, this project's a365-kit.config.json, the default baked
    into the kit at build time, and finally the public GitHub release.

.PARAMETER SetUpdateSource
    Persist an update source for this project in a365-kit.config.json (commit it so the whole
    team updates from the same place) and exit. Use it when your organisation mirrors the kit
    on its own server or share. Pass an empty string to clear it.

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
    [string] $Launch,
    [switch] $Update,
    [string] $UpdateFrom,
    [string] $SetUpdateSource
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

# -- Update source --------------------------------------------------------------
# Resolved in this order so an organisation that mirrors the kit internally can pin
# it once and forget it:
#   1. -UpdateFrom                (this call)
#   2. $env:A365_KIT_UPDATE_SOURCE (this shell / CI job)
#   3. a365-kit.config.json       (this project -- lives OUTSIDE the paths -Update replaces)
#   4. .a365-kit\KIT-VERSION.json (default baked in at build time)
#   5. the public GitHub release

$KitConfigPath = Join-Path $KitRoot 'a365-kit.config.json'
$PublicSource  = 'https://github.com/AkramMSFT/agent365-onboarding-kit/releases/latest/download/agent365-onboarding-kit-latest.zip'

function Get-UpdateSource {
    if ($UpdateFrom) { return @{ Value = $UpdateFrom; Origin = '-UpdateFrom' } }
    if ($env:A365_KIT_UPDATE_SOURCE) { return @{ Value = $env:A365_KIT_UPDATE_SOURCE; Origin = 'A365_KIT_UPDATE_SOURCE' } }
    if (Test-Path -LiteralPath $KitConfigPath) {
        try {
            $c = Get-Content -LiteralPath $KitConfigPath -Raw | ConvertFrom-Json
            if ($c.updateSource) { return @{ Value = [string]$c.updateSource; Origin = 'a365-kit.config.json' } }
        } catch { Write-Warn "a365-kit.config.json is not valid JSON -- ignoring it" }
    }
    $m = Join-Path $KitRoot '.a365-kit\KIT-VERSION.json'
    if (Test-Path -LiteralPath $m) {
        try {
            $mv = (Get-Content -LiteralPath $m -Raw | ConvertFrom-Json).updateSource
            if ($mv) { return @{ Value = [string]$mv; Origin = 'kit build default' } }
        } catch { }
    }
    return @{ Value = $PublicSource; Origin = 'public GitHub release' }
}

if ($PSBoundParameters.ContainsKey('SetUpdateSource')) {
    Write-Head 'Kit update source'
    $cfg = @{}
    if (Test-Path -LiteralPath $KitConfigPath) {
        try { $cfg = Get-Content -LiteralPath $KitConfigPath -Raw | ConvertFrom-Json -AsHashtable } catch { $cfg = @{} }
    }
    if ([string]::IsNullOrWhiteSpace($SetUpdateSource)) {
        $cfg.Remove('updateSource')
        Write-Ok 'Cleared the project update source.'
    } else {
        $cfg['updateSource'] = $SetUpdateSource
        Write-Ok "Project update source set to: $SetUpdateSource"
    }
    ($cfg | ConvertTo-Json) | Set-Content -LiteralPath $KitConfigPath -Encoding UTF8
    Write-Note 'Written to a365-kit.config.json -- commit it so your whole team updates from the same place.'
    $r = Get-UpdateSource
    Write-Note "-Update will now use: $($r.Value)  [$($r.Origin)]"
    Write-Host ''
    exit 0
}

# -- 0. Self-update ------------------------------------------------------------
# Replaces kit paths only. Anything the user owns is left alone, and the set of
# skill folders to replace is read from the NEW kit's manifest, so a skill that
# upstream removes is removed here too rather than lingering.

if ($Update) {
    Write-Head 'Updating the kit'
    $resolved = Get-UpdateSource
    $UpdateFrom = $resolved.Value
    Write-Note "Source  : $UpdateFrom  [$($resolved.Origin)]"
    $stage = Join-Path ([IO.Path]::GetTempPath()) ("a365-kit-update-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $zip = Join-Path $stage 'kit.zip'
    try {
        if ($UpdateFrom -match '^https?://') {
            Write-Note "Downloading $UpdateFrom"
            Invoke-WebRequest -Uri $UpdateFrom -OutFile $zip -UseBasicParsing
        } else {
            if (-not (Test-Path -LiteralPath $UpdateFrom)) { Write-Err "Not found: $UpdateFrom"; exit 1 }
            Copy-Item -LiteralPath $UpdateFrom -Destination $zip
        }
        $new = Join-Path $stage 'new'
        Expand-Archive -Path $zip -DestinationPath $new -Force
        $manifestPath = Join-Path $new '.a365-kit\KIT-VERSION.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Err 'That archive is not an Agent 365 Onboarding Kit (no .a365-kit\KIT-VERSION.json).'; exit 1 }
        $newManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $oldManifestPath = Join-Path $KitRoot '.a365-kit\KIT-VERSION.json'
        $oldDesc = if (Test-Path -LiteralPath $oldManifestPath) {
            $o = Get-Content -LiteralPath $oldManifestPath -Raw | ConvertFrom-Json
            "kit v$($o.kitVersion) / upstream v$($o.upstreamVersion) ($($o.upstreamCommit))"
        } else { 'no kit installed' }
        Write-Note "Current : $oldDesc"
        Write-Note "New     : kit v$($newManifest.kitVersion) / upstream v$($newManifest.upstreamVersion) ($($newManifest.upstreamCommit))"

        $skillNames = @($newManifest.skills) + @($newManifest.addons)
        if (Test-Path -LiteralPath $oldManifestPath) {
            $o = Get-Content -LiteralPath $oldManifestPath -Raw | ConvertFrom-Json
            $skillNames += @($o.skills) + @($o.addons)      # remove anything the new kit dropped
        }
        $skillNames = $skillNames | Where-Object { $_ } | Sort-Object -Unique

        # 1. canonical folder
        $dst = Join-Path $KitRoot '.a365-kit'
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Copy-Item -LiteralPath (Join-Path $new '.a365-kit') -Destination $dst -Recurse
        # 2. discovery copies -- only the kit's own skill folders
        foreach ($disc in @('.claude\skills', '.agents\skills')) {
            $target = Join-Path $KitRoot $disc
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            foreach ($name in $skillNames) {
                $old = Join-Path $target $name
                if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
                $src = Join-Path (Join-Path $new $disc) $name
                if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $old -Recurse }
            }
        }
        # 3. launchers + kit README
        foreach ($f in @('agent365-kit.ps1', 'agent365-kit.sh', 'AGENT365-KIT-README.md')) {
            $src = Join-Path $new $f
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $KitRoot $f) -Force }
        }
        Write-Ok "Kit updated to v$($newManifest.kitVersion) (upstream v$($newManifest.upstreamVersion), $($newManifest.upstreamCommit))"
        Write-Note 'Your agent files, .env, a365 config and .claude\settings.json were not touched.'
        Write-Note 'The launcher you are running is now the old copy; re-run .\agent365-kit.ps1 to use the new one.'
        Write-Host ''
        exit 0
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

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
$AddonPath  = Join-Path $KitRoot '.a365-kit\addons'
$AddonNames = @(if (Test-Path -LiteralPath $AddonPath) { (Get-ChildItem -Path $AddonPath -Directory).Name })
Write-Host ''
Write-Ok "Kit layout looks correct ($($SkillCount + $AddonNames.Count) skills: $SkillCount Microsoft, $($AddonNames.Count) add-ons)"

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

# NOTE: the parameter is deliberately NOT called $Args -- that is a PowerShell
# automatic variable, and using it as a parameter name silently breaks binding,
# so `& gh @Args` runs gh with no arguments, prints help, and exits 0. That makes
# every probe report success.
function Test-Cli { param([string] $Exe, [string[]] $Arguments)
    try {
        & $Exe @Arguments *> $null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

$hasClaude = [bool](Get-Command claude -ErrorAction SilentlyContinue)
$hasGh     = [bool](Get-Command gh     -ErrorAction SilentlyContinue)
$hasCode   = [bool](Get-Command code   -ErrorAction SilentlyContinue)

# `gh skill` and `gh copilot` are built into gh 2.98+, not extensions, and neither
# supports --version: `gh skill --version` errors with "unknown flag", and
# `gh copilot --version` reports on the *downloaded Copilot CLI*, not on gh itself.
# Probe --help for availability, and --version only to tell whether the Copilot CLI
# binary is actually present.
$hasGhSkill    = $false   # gh can install agent skills
$hasGhCopilotL = $false   # gh can launch the Copilot CLI (downloads on first use)
if ($hasGh) {
    $hasGhSkill    = Test-Cli 'gh' @('skill', '--help')
    $hasGhCopilotL = Test-Cli 'gh' @('copilot', '--help')
}
# The agentic Copilot CLI itself, either standalone on PATH or already downloaded by gh.
$hasCopilotCli = [bool](Get-Command copilot -ErrorAction SilentlyContinue)
if (-not $hasCopilotCli -and $hasGhCopilotL) {
    $hasCopilotCli = Test-Cli 'gh' @('copilot', '--version')
}

Write-Head 'Detected CLIs'
if ($hasClaude)     { Write-Ok 'Claude Code' }               else { Write-Note '  --   Claude Code (not installed)' }
if ($hasCopilotCli) { Write-Ok 'GitHub Copilot CLI' }
elseif ($hasGhCopilotL) { Write-Note '  ~    GitHub Copilot CLI (not installed; gh will fetch it on first use)' }
else                { Write-Note '  --   GitHub Copilot CLI (not available)' }
if ($hasGhSkill)    { Write-Ok 'gh skill (agent-skill installer)' } else { Write-Note '  --   gh skill (needs gh 2.98+)' }
if ($hasCode)       { Write-Ok 'VS Code' }                   else { Write-Note '  --   VS Code (not installed)' }

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

Write-Host '  GitHub Copilot CLI' -ForegroundColor White
Write-Note '    Reads .agents/skills/ automatically. From this folder:'
Write-Cmd 'gh copilot'
Write-Note '    then type the phrase above. For extra grounding, also wire the'
Write-Note '    instructions file once:'
Write-Cmd '.\agent365-kit.ps1 -WireCopilot'
Write-Host ''

Write-Host '  VS Code (Copilot agent mode)' -ForegroundColor White
Write-Note '    Open this folder in VS Code, switch Copilot Chat to Agent mode,'
Write-Note '    confirm the skills with /skills list, then ask using the phrase above.'
Write-Host ''

Write-Host '  Cursor, Codex, Gemini CLI, Amp, Cline, OpenCode, Warp, Antigravity' -ForegroundColor White
Write-Note '    All of these share the .agents/skills/ directory at project scope, so the'
Write-Note '    skills are already where they look. Open this folder and use the phrase above.'
Write-Host ''

Write-Host '  Any other agentic CLI' -ForegroundColor White
Write-Note '    Point it at .a365-kit/skills/a365-setup/SKILL.md and tell it to follow that file.'
Write-Note '    The skills are plain Markdown -- nothing is Claude-specific except the'
Write-Note '    validator hooks, which are optional.'
Write-Host ''
Write-Note 'Full per-CLI walkthrough: docs/USING-WITH-YOUR-CLI.md in the kit repository.'
Write-Host ''

Write-Head 'What you can ask for'
Write-Host ''
Write-Note 'Say these in whichever CLI you picked. You do not need to know skill names.'
Write-Host ''

Write-Host '  Core' -ForegroundColor White
Write-Cmd '"Onboard this agent to Agent 365."'
Write-Note '        blueprint, Entra identity, permissions'
Write-Cmd '"Add observability to this agent."'
Write-Note '        OpenTelemetry and the Agent 365 exporter'
Write-Cmd '"Add WorkIQ tools to this agent."'
Write-Note '        Microsoft 365 data: mail, calendar, Teams, SharePoint'
Write-Cmd '"Validate A365 code."'
Write-Note '        read-only check of telemetry, identity binding and grants'
Write-Host ''

# Enumerated, not hardcoded: a new add-on appears here without touching the launcher.
$AddonPhrases = @{
  'add-messaging-endpoint' = @('"Make this agent chattable in Teams."', 'HTTP host, dev tunnel, endpoint registration')
  'test-local-channel'     = @('"Let me test this agent locally."', 'loopback-only dev channel: no tunnel, no tenant, no Teams')
  'add-mcp-server'         = @('"Add an MCP server."', 'any external MCP server -- not governed by Agent 365')
  'add-lab-tools'          = @('"Add lab tools."', 'local utilities: web fetch, encoders, hashing, text transforms')
  'add-purview-dlp'        = @('"Add DLP to this agent."', 'Purview checks every prompt and response')
  'add-java-agent'         = @('"Onboard this Java agent."', 'hosting and telemetry for Java, which has no Microsoft SDK')
  'a365-kit'               = @('"Update the Agent 365 kit."', 'replaces only the kit files, never your agent')
}
if ($AddonNames.Count -gt 0) {
    Write-Host '  Add-ons in this kit' -ForegroundColor White
    foreach ($addon in ($AddonNames | Sort-Object)) {
        if ($AddonPhrases.ContainsKey($addon)) {
            Write-Cmd  $AddonPhrases[$addon][0]
            Write-Note ('        ' + $AddonPhrases[$addon][1])
        } else {
            Write-Cmd  $addon
            Write-Note ('        see .a365-kit/addons/' + $addon + '/SKILL.md')
        }
    }
    Write-Host ''
}

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
