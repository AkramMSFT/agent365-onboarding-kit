<#
.SYNOPSIS
    Agent 365 Onboarding Kit: prerequisite check and per-CLI activation steps.

.DESCRIPTION
    Run this from the root of your agent project after extracting the kit into it.
    The skills do the onboarding. This script only:

      1. Confirms the kit extracted to the right place.
      2. Warns if you are in an elevated shell (a common cause of "command not found").
      3. Checks prerequisites and prints the install command for anything missing.
      4. Detects which agentic CLIs you have installed.
      5. Prints the exact steps to load the skills in each one.

    The skills work with any CLI that reads one of these locations:
      .claude/skills/    Claude Code, GitHub Copilot CLI
      .agents/skills/    GitHub Copilot CLI, VS Code agent mode, Copilot cloud agent, gh skill
      .github/copilot-instructions.md   VS Code Copilot Chat; extra grounding for Copilot CLI

.PARAMETER DoctorOnly
    Run the prerequisite check and exit, without printing activation steps.

.PARAMETER SkipDoctor
    Skip the prerequisite check and go straight to the activation steps.

.PARAMETER WireCopilot
    Create or append the Agent 365 skill instructions to .github/copilot-instructions.md.
    An existing file is appended to once, never overwritten.

.PARAMETER WireClaudeHook
    Add the optional SessionStart upstream-version notice to .claude/settings.json.
    Skipped automatically if that file already exists.

.PARAMETER Launch
    The CLI to launch once the checks pass. Only 'claude' is supported.

.PARAMETER Update
    Replace the kit in this project with the latest release. Touches only kit paths
    (.a365-kit, the kit's own skill folders under .claude/skills and .agents/skills, the
    launchers, and AGENT365-KIT-README.md). Your agent, .env, config and .claude/settings.json
    are never modified.

.PARAMETER UpdateFrom
    One-off override of where -Update fetches the kit from: a .zip path (local or file share)
    or an HTTPS URL. Without it the source is resolved, in order, from the environment
    variable A365_KIT_UPDATE_SOURCE, this project's a365-kit.config.json, the default baked
    into the kit at build time, and finally the public GitHub release.
    Relative paths saved in project config or the build manifest resolve from the project;
    one-off and environment overrides resolve from the caller's working directory.

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

# a365-kit.config.json sits outside the paths -Update replaces, so a team that
# mirrors the kit can set its update source once.
$KitConfigPath = Join-Path $KitRoot 'a365-kit.config.json'
$PublicSource  = 'https://github.com/AkramMSFT/agent365-sdk-onboarding-experience/releases/latest/download/agent365-onboarding-kit-latest.zip'

# Windows PowerShell 5.1 reads BOM-less files in the ANSI code page, writes a BOM with
# -Encoding UTF8 and has no ConvertFrom-Json -AsHashtable, so these helpers avoid them.
function Read-KitText([string] $Path) { [IO.File]::ReadAllText($Path) }
function Write-KitText([string] $Path, [string] $Text, [switch] $Append) {
    $utf8 = [Text.UTF8Encoding]::new($false)
    if ($Append) { [IO.File]::AppendAllText($Path, $Text, $utf8) } else { [IO.File]::WriteAllText($Path, $Text, $utf8) }
}
function ConvertFrom-KitJson([string] $Json) {
    if ($PSVersionTable.PSVersion.Major -ge 7) { return ,($Json | ConvertFrom-Json -AsHashtable -NoEnumerate) }
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $serializer.MaxJsonLength = [int]::MaxValue
    return ,$serializer.DeserializeObject($Json)
}

function Get-UpdateSource {
    if ($UpdateFrom) { return @{ Value = $UpdateFrom; Origin = '-UpdateFrom' } }
    if ($env:A365_KIT_UPDATE_SOURCE) { return @{ Value = $env:A365_KIT_UPDATE_SOURCE; Origin = 'A365_KIT_UPDATE_SOURCE' } }
    if (Test-Path -LiteralPath $KitConfigPath) {
        try {
            $c = ConvertFrom-KitJson (Read-KitText $KitConfigPath)
            if ($c -is [System.Collections.IDictionary] -and $c['updateSource'] -is [string] -and -not [string]::IsNullOrWhiteSpace($c['updateSource'])) {
                return @{ Value = $c['updateSource']; Origin = 'a365-kit.config.json' }
            }
        } catch { Write-Warn "a365-kit.config.json is not valid JSON -- ignoring it" }
    }
    $m = Join-Path $KitRoot '.a365-kit\KIT-VERSION.json'
    if (Test-Path -LiteralPath $m) {
        try {
            $mv = ConvertFrom-KitJson (Read-KitText $m)
            if ($mv -is [System.Collections.IDictionary] -and $mv['updateSource'] -is [string] -and -not [string]::IsNullOrWhiteSpace($mv['updateSource'])) {
                return @{ Value = $mv['updateSource']; Origin = 'kit build default' }
            }
        } catch { }
    }
    return @{ Value = $PublicSource; Origin = 'public GitHub release' }
}

if ($PSBoundParameters.ContainsKey('SetUpdateSource')) {
    Write-Head 'Kit update source'
    $cfg = @{}
    if (Test-Path -LiteralPath $KitConfigPath) {
        $cfg = ConvertFrom-KitJson (Read-KitText $KitConfigPath)
        if ($cfg -isnot [System.Collections.IDictionary]) {
            throw 'a365-kit.config.json must contain a JSON object; it was not changed.'
        }
    }
    if ([string]::IsNullOrWhiteSpace($SetUpdateSource)) {
        $null = $cfg.Remove('updateSource')
        Write-Ok 'Cleared the project update source.'
    } else {
        $cfg['updateSource'] = $SetUpdateSource
        Write-Ok "Project update source set to: $SetUpdateSource"
    }
    Write-KitText $KitConfigPath (($cfg | ConvertTo-Json -Depth 100 -WarningAction Stop) + "`n")
    Write-Note 'Written to a365-kit.config.json -- commit it so your whole team updates from the same place.'
    $r = Get-UpdateSource
    Write-Note "-Update will now use: $($r.Value)  [$($r.Origin)]"
    Write-Host ''
    exit 0
}

# Skill folders to replace come from both the old and the new manifest, so a skill
# that upstream dropped is removed rather than left behind.
if ($Update) {
    Write-Head 'Updating the kit'
    $resolved = Get-UpdateSource
    $UpdateFrom = $resolved.Value
    Write-Note "Source  : $UpdateFrom  [$($resolved.Origin)]"
    if ($resolved.Origin -in @('a365-kit.config.json', 'kit build default') -and
        $UpdateFrom -notmatch '^https?://' -and -not [IO.Path]::IsPathRooted($UpdateFrom)) {
        $UpdateFrom = Join-Path $KitRoot $UpdateFrom
    }

    function Read-KitManifest([string] $Path) {
        $data = ConvertFrom-KitJson (Read-KitText $Path)
        if ($data -isnot [System.Collections.IDictionary]) { throw "Invalid kit manifest: $Path" }
        foreach ($field in @('kitVersion', 'upstreamVersion', 'upstreamCommit')) {
            if ($data[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($data[$field])) {
                throw "Invalid $field in kit manifest: $Path"
            }
        }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($field in @('skills', 'addons')) {
            if ($data[$field] -isnot [array]) { throw "Invalid $field array in kit manifest: $Path" }
            foreach ($name in $data[$field]) {
                if ($name -isnot [string] -or $name -cnotmatch '^[a-z0-9][a-z0-9_-]*$' -or -not $seen.Add($name)) {
                    throw "Invalid or duplicate skill name in kit manifest: $Path"
                }
            }
        }
        if ($data.skills -cnotcontains 'a365-setup') { throw "Kit manifest is missing a365-setup: $Path" }
        return $data
    }

    function Assert-UpdatePath([string] $Relative, [switch] $Directory) {
        $item = Get-Item -LiteralPath (Join-Path $KitRoot $Relative) -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing to replace a linked project path: $Relative"
        }
        if ($item -and $Directory -and -not $item.PSIsContainer) {
            throw "Expected a project directory: $Relative"
        }
    }

    # Short name: Windows PowerShell 5.1 cannot extract past 260 characters.
    $stage = Join-Path $KitRoot ('.a365-kit-update-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $stage | Out-Null
    $zip = Join-Path $stage 'kit.zip'
    $backedUp = [Collections.Generic.List[string]]::new()
    $installed = [Collections.Generic.List[string]]::new()
    $keepBackup = $false
    try {
        if ($UpdateFrom -match '^https?://') {
            Write-Note "Downloading $UpdateFrom"
            Invoke-WebRequest -Uri $UpdateFrom -OutFile $zip -UseBasicParsing
        } else {
            if (-not (Test-Path -LiteralPath $UpdateFrom -PathType Leaf)) { throw "Not found: $UpdateFrom" }
            Copy-Item -LiteralPath $UpdateFrom -Destination $zip
        }
        # The archive is untrusted: check entry paths before extracting and completeness
        # before moving any installed file.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $entries = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $archive.Entries) {
                $name = $entry.FullName.Replace('\', '/').TrimEnd('/')
                if (-not $name -or $name.StartsWith('/') -or $name.Contains(':') -or
                    ($name.Split('/') | Where-Object { $_ -in @('', '.', '..') }) -or
                    -not $entries.Add($name) -or
                    (($entry.ExternalAttributes -shr 16) -band 0xf000) -eq 0xa000) {
                    throw "Unsafe or duplicate archive path: $($entry.FullName)"
                }
            }
        } finally { $archive.Dispose() }
        $new = Join-Path $stage 'new'
        Expand-Archive -LiteralPath $zip -DestinationPath $new -Force
        foreach ($item in Get-ChildItem -LiteralPath $new -Recurse -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked archive entry: $($item.FullName)" }
        }
        $manifestPath = Join-Path $new '.a365-kit\KIT-VERSION.json'
        $newManifest = Read-KitManifest $manifestPath
        $oldManifestPath = Join-Path $KitRoot '.a365-kit\KIT-VERSION.json'
        Assert-UpdatePath '.a365-kit'
        Assert-UpdatePath '.a365-kit\KIT-VERSION.json'
        $oldNames = @()
        $oldDesc = if (Test-Path -LiteralPath $oldManifestPath) {
            $o = Read-KitManifest $oldManifestPath
            $oldNames = @($o.skills) + @($o.addons)
            "kit v$($o.kitVersion) / upstream v$($o.upstreamVersion) ($($o.upstreamCommit))"
        } else { 'no kit installed' }
        Write-Note "Current : $oldDesc"
        Write-Note "New     : kit v$($newManifest.kitVersion) / upstream v$($newManifest.upstreamVersion) ($($newManifest.upstreamCommit))"

        $newNames = @($newManifest.skills) + @($newManifest.addons)
        $skillNames = @($newNames + $oldNames | Sort-Object -Unique)
        $files = @('agent365-kit.ps1', 'agent365-kit.sh', 'AGENT365-KIT-README.md')
        $required = $files + @('.a365-kit\doctor.js', '.a365-kit\kit-version.js',
            '.a365-kit\settings-fragment.json', '.a365-kit\copilot-instructions.md')
        foreach ($kind in @('skills', 'addons')) {
            foreach ($name in $newManifest[$kind]) {
                $required += ".a365-kit\$kind\$name\SKILL.md", ".claude\skills\$name\SKILL.md", ".agents\skills\$name\SKILL.md"
            }
        }
        foreach ($relative in $required) {
            $file = Join-Path $new $relative
            if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file -Force).Length -eq 0) {
                throw "Incomplete kit archive: missing or empty $relative"
            }
        }

        $operations = @(@{ Relative = '.a365-kit'; Install = $true })
        foreach ($parent in @('.claude', '.agents')) {
            $disc = "$parent\skills"
            Assert-UpdatePath $parent -Directory
            Assert-UpdatePath $disc -Directory
            foreach ($name in $skillNames) {
                $relative = "$disc\$name"
                Assert-UpdatePath $relative
                if ($name -notin $oldNames -and (Test-Path -LiteralPath (Join-Path $KitRoot $relative))) {
                    throw "A new kit skill conflicts with a project-owned skill: $relative"
                }
                $operations += @{ Relative = $relative; Install = $name -in $newNames }
            }
        }
        foreach ($file in $files) {
            Assert-UpdatePath $file
            $operations += @{ Relative = $file; Install = $true }
        }
        foreach ($operation in $operations) {
            $relative = $operation.Relative
            $dst = Join-Path $KitRoot $relative
            if (Test-Path -LiteralPath $dst) {
                $backup = Join-Path (Join-Path $stage 'backup') $relative
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
                Move-Item -LiteralPath $dst -Destination $backup
                $backedUp.Add($relative)
            }
            if ($operation.Install) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
                $installed.Add($relative)
                Move-Item -LiteralPath (Join-Path $new $relative) -Destination $dst
            }
        }
        Write-Ok "Kit updated to v$($newManifest.kitVersion) (upstream v$($newManifest.upstreamVersion), $($newManifest.upstreamCommit))"
        Write-Note 'Your agent files, .env, a365 config and .claude\settings.json were not touched.'
        Write-Note 'The launcher you are running is now the old copy; re-run .\agent365-kit.ps1 to use the new one.'
        Write-Host ''
        exit 0
    }
    catch {
        $failure = $_
        for ($i = $installed.Count - 1; $i -ge 0; $i--) {
            try {
                $dst = Join-Path $KitRoot $installed[$i]
                if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
            }
            catch { $keepBackup = $true }
        }
        for ($i = $backedUp.Count - 1; $i -ge 0; $i--) {
            $relative = $backedUp[$i]
            try {
                $dst = Join-Path $KitRoot $relative
                if (Test-Path -LiteralPath $dst) { throw "Rollback destination still exists: $dst" }
                Move-Item -LiteralPath (Join-Path (Join-Path $stage 'backup') $relative) -Destination $dst
            } catch { $keepBackup = $true }
        }
        if ($keepBackup) { Write-Err "Rollback was incomplete; the original files remain under $stage\backup." }
        throw $failure
    }
    finally {
        if (-not $keepBackup) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

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

$SkillCount = @(Get-ChildItem -LiteralPath (Join-Path $KitRoot '.a365-kit\skills') -Directory).Count
$AddonPath  = Join-Path $KitRoot '.a365-kit\addons'
$AddonNames = @(if (Test-Path -LiteralPath $AddonPath) { (Get-ChildItem -LiteralPath $AddonPath -Directory).Name })
Write-Host ''
Write-Ok "Kit layout looks correct ($($SkillCount + $AddonNames.Count) skills: $SkillCount Microsoft, $($AddonNames.Count) add-ons)"

if ((Get-Location).Path -ne $KitRoot) {
    Write-Warn "Switching working directory to the project root: $KitRoot"
    Set-Location -LiteralPath $KitRoot
}

$isElevated = $false
if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if ($isElevated) {
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

if ($WireCopilot) {
    Write-Head 'Wiring GitHub Copilot instructions'
    $src = Join-Path $KitRoot '.a365-kit\copilot-instructions.md'
    $dstDir = Join-Path $KitRoot '.github'
    $dst = Join-Path $dstDir 'copilot-instructions.md'

    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        Write-Err 'Missing .a365-kit\copilot-instructions.md -- kit may be incomplete.'
        exit 1
    }
    else {
        $instructions = Read-KitText $src
        if ([string]::IsNullOrWhiteSpace($instructions)) { throw 'The kit Copilot instructions are empty.' }
        $marker = '<!-- agent365-kit:copilot-instructions -->'
        $existing = if (Test-Path -LiteralPath $dst) { (Read-KitText $dst) } else { '' }
        $alreadyWired = $existing.Contains($marker) -or
            $existing.Replace("`r`n", "`n").Contains($instructions.Replace("`r`n", "`n").TrimEnd())
        $block = "$marker`n$instructions"
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        if (-not (Test-Path -LiteralPath $dst)) {
            Write-KitText $dst ($block.TrimEnd() + "`n")
            Write-Ok 'Created .github\copilot-instructions.md'
        }
        elseif ($alreadyWired) {
            Write-Ok 'Already wired -- .github\copilot-instructions.md contains the kit instructions.'
        }
        else {
            # Append rather than overwrite: this file is commonly project-owned.
            Write-KitText $dst ("`n`n---`n`n" + $block.TrimEnd() + "`n") -Append
            Write-Ok 'Appended Agent 365 instructions to your existing .github\copilot-instructions.md'
        }
    }
}

if ($WireClaudeHook) {
    Write-Head 'Wiring the optional upstream-version notice'
    $fragment = Join-Path $KitRoot '.a365-kit\settings-fragment.json'
    $settings = Join-Path $KitRoot '.claude\settings.json'
    if (Test-Path -LiteralPath $settings) {
        if (-not (Test-Path -LiteralPath $settings -PathType Leaf)) {
            throw '.claude\settings.json exists but is not a file; it was not changed.'
        }
        Write-Warn 'This project already has .claude\settings.json -- leaving it untouched.'
        Write-Note 'Merge the "hooks" block from .a365-kit\settings-fragment.json by hand.'
    }
    else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settings) | Out-Null
        Copy-Item -LiteralPath $fragment -Destination $settings
        Write-Ok 'Created .claude\settings.json'
    }
}

# Not named $Args: that automatic variable breaks parameter binding, so `& gh @Args`
# would run gh with no arguments, print help and exit 0, and every probe would pass.
function Test-Cli { param([string] $Exe, [string[]] $Arguments)
    try {
        & $Exe @Arguments *> $null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

$hasClaude = [bool](Get-Command claude -ErrorAction SilentlyContinue)
$hasGh     = [bool](Get-Command gh     -ErrorAction SilentlyContinue)
$hasCode   = [bool](Get-Command code   -ErrorAction SilentlyContinue)

# `gh skill` and `gh copilot` are built into gh 2.98+ and have no safe --version probe:
# `gh skill --version` errors and `gh copilot --version` can download the Copilot CLI.
$hasGhSkill    = $false
$hasGhCopilotL = $false   # gh can launch the Copilot CLI, downloading it on first use
if ($hasGh) {
    $hasGhSkill    = Test-Cli 'gh' @('skill', '--help')
    $hasGhCopilotL = Test-Cli 'gh' @('copilot', '--help')
}
$hasCopilotCli = [bool](Get-Command copilot -ErrorAction SilentlyContinue)

Write-Head 'Detected CLIs'
if ($hasClaude)     { Write-Ok 'Claude Code' }               else { Write-Note '  --   Claude Code (not installed)' }
if ($hasCopilotCli) { Write-Ok 'GitHub Copilot CLI' }
elseif ($hasGhCopilotL) { Write-Note '  ~    GitHub Copilot CLI (available through gh copilot; resolved on first launch)' }
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
Write-Cmd $(if ($hasCopilotCli -or -not $hasGhCopilotL) { 'copilot' } else { 'gh copilot' })
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
Write-Cmd '"Add Purview DLP to my agent."'
Write-Note '        Purview blocks sensitive prompts before the model; replies can be audited'
Write-Host ''

# Add-ons are listed from disk, so one without an entry here still shows up.
$AddonPhrases = @{
  'add-messaging-endpoint' = @('"Make this agent chattable in Teams."', 'HTTP host, dev tunnel, endpoint registration')
  'test-local-channel'     = @('"Let me test this agent locally."', 'loopback-only dev channel: no tunnel, no tenant, no Teams')
  'add-mcp-server'         = @('"Add an MCP server."', 'any external MCP server -- not governed by Agent 365')
  'add-lab-tools'          = @('"Add lab tools."', 'local utilities: web fetch, encoders, hashing, text transforms')
  'add-java-agent'         = @('"Onboard this Java agent."', 'hosting and telemetry for Java, which has no Microsoft SDK')
  'a365-kit'               = @('"Update the Agent 365 kit."', 'replaces only the kit files, never your agent')
  'grant-observability-access' = @('"Grant observability access to this agent."', 'the maven-prod OtelWrite permission; an administrator confirms the grant')
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
Write-Note 'Run a365 setup in your own terminal when the skill asks. To have the kit catch'
Write-Note 'the observability consent hand-off, prefix the same command with the wrapper:'
Write-Cmd 'node .\.a365-kit\run-a365.mjs setup <subcommand> [options]'
Write-Note 'If setup says maven-prod OtelWrite needs admin consent, ask: "Grant observability access to this agent."'
Write-Host ''

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

exit 0
