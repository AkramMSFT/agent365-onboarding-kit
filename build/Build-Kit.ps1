<#
.SYNOPSIS
    Builds the distributable Agent 365 Onboarding Kit from upstream microsoft/agent365-skills.

.DESCRIPTION
    Turns Microsoft's agent365-skills plugin into a drop-in folder that works with any
    agentic CLI, with no plugin install and no marketplace step.

    What it produces in -OutDir:

        .a365-kit/                  canonical content -- skills, shared docs, hook validators
        .claude/skills/             discovery copy for Claude Code
        .agents/skills/             discovery copy for VS Code agent mode / gh skill
        agent365-kit.ps1|.sh        prereq check + per-CLI activation steps
        AGENT365-KIT-README.md      what to do after extracting

    The upstream skills reference sibling files through ${CLAUDE_PLUGIN_ROOT}, which only
    resolves when the skills are loaded as a plugin. Because .a365-kit/ mirrors the upstream
    layout exactly (skills/, shared/, hooks/), rewriting that token to the relative path
    ".a365-kit" fixes every in-body reference in one substitution. Hook *commands* are a
    separate case -- those are executed by Claude Code, so they get ${CLAUDE_PROJECT_DIR},
    which is expanded reliably and is quoted here to survive spaces in the path.

.PARAMETER UpstreamPath
    Path to an existing clone of microsoft/agent365-skills. If omitted, the script performs
    a shallow clone into a temp folder and removes it afterwards.

.PARAMETER UpstreamRef
    Branch or tag to clone when -UpstreamPath is not supplied. Default: main.

.PARAMETER OutDir
    Output directory. Default: <repo>/dist

.PARAMETER Zip
    Also produce dist/agent365-onboarding-kit-<version>.zip, ready to attach to a release.

.PARAMETER KitVersion
    Version stamp for this kit. Default: read from build/kit.version, else 0.1.0.

.EXAMPLE
    .\build\Build-Kit.ps1 -UpstreamPath C:\src\agent365-skills

.EXAMPLE
    .\build\Build-Kit.ps1 -Zip
#>
[CmdletBinding()]
param(
    [string] $UpstreamPath,
    [string] $UpstreamRef = 'main',
    [string] $OutDir,
    [switch] $Zip,
    [string] $KitVersion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$PayloadDir  = Join-Path $RepoRoot 'payload'
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'dist' }

$KIT_DIR = '.a365-kit'   # canonical folder name inside the user's project

function Step { param([string] $T) Write-Host ''; Write-Host "==> $T" -ForegroundColor Cyan }
function Ok   { param([string] $T) Write-Host "    [ok]   $T" -ForegroundColor Green }
function Info { param([string] $T) Write-Host "    $T" -ForegroundColor Gray }
function Warn { param([string] $T) Write-Host "    [warn] $T" -ForegroundColor Yellow }
function Fail { param([string] $T) Write-Host "    [FAIL] $T" -ForegroundColor Red }

if (-not $KitVersion) {
    $versionFile = Join-Path $RepoRoot 'build\kit.version'
    $KitVersion = if (Test-Path -LiteralPath $versionFile) {
        (Get-Content -LiteralPath $versionFile -Raw).Trim()
    } else { '0.1.0' }
}

Write-Host ''
Write-Host 'Agent 365 Onboarding Kit -- build' -ForegroundColor White
Write-Host '=================================' -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 1. Resolve upstream
# ---------------------------------------------------------------------------

Step 'Resolving upstream (microsoft/agent365-skills)'

$TempClone = $null
if ($UpstreamPath) {
    if (-not (Test-Path -LiteralPath $UpstreamPath)) {
        throw "UpstreamPath not found: $UpstreamPath"
    }
    $Upstream = (Resolve-Path -LiteralPath $UpstreamPath).Path
    Ok "Using existing clone: $Upstream"
} else {
    $TempClone = Join-Path ([IO.Path]::GetTempPath()) ("a365-upstream-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    Info "Shallow-cloning $UpstreamRef into $TempClone"
    # core.longpaths: the upstream repo is fine today, but this costs nothing and
    # has bitten other Agent 365 clones on Windows (MAX_PATH).
    & git -c core.longpaths=true clone --depth 1 --branch $UpstreamRef `
        https://github.com/microsoft/agent365-skills.git $TempClone 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)" }
    $Upstream = $TempClone
    Ok "Cloned $UpstreamRef"
}

$PluginRoot = Join-Path $Upstream 'plugins\agent365'
foreach ($required in @('skills', 'shared', 'hooks', '.claude-plugin\plugin.json')) {
    $p = Join-Path $PluginRoot $required
    if (-not (Test-Path -LiteralPath $p)) {
        throw "Upstream layout unexpected -- missing: plugins/agent365/$required"
    }
}

$UpstreamVersion = (Get-Content -LiteralPath (Join-Path $PluginRoot '.claude-plugin\plugin.json') -Raw |
    ConvertFrom-Json).version
$UpstreamCommit = (& git -C $Upstream rev-parse --short HEAD 2>$null)
if ($LASTEXITCODE -ne 0) { $UpstreamCommit = 'unknown' }

Ok "upstream agent365-skills v$UpstreamVersion ($UpstreamCommit)"
Ok "building kit v$KitVersion"

try {

# ---------------------------------------------------------------------------
# 2. Stage canonical content
# ---------------------------------------------------------------------------

Step "Staging canonical content into $KIT_DIR/"

if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$KitPath = Join-Path $OutDir $KIT_DIR
New-Item -ItemType Directory -Force -Path $KitPath | Out-Null

foreach ($dir in @('skills', 'shared', 'hooks')) {
    Copy-Item -LiteralPath (Join-Path $PluginRoot $dir) -Destination $KitPath -Recurse
    Ok "copied $dir/"
}

# ---------------------------------------------------------------------------
# 3. Rewrite plugin-root references
# ---------------------------------------------------------------------------

Step 'Rewriting ${CLAUDE_PLUGIN_ROOT} references'

$skillFiles = Get-ChildItem -Path (Join-Path $KitPath 'skills') -Filter 'SKILL.md' -Recurse
$rewritten = 0

foreach ($file in $skillFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    $before = $text

    # (a) Hook COMMANDS are executed by the host, so they need an absolute path.
    #     ${CLAUDE_PROJECT_DIR} is expanded by Claude Code; quote it for spaces.
    $text = [regex]::Replace(
        $text,
        'command:\s*node\s+\$\{CLAUDE_PLUGIN_ROOT\}/(?<rest>[^\r\n]+?)(?=\s*$)',
        { param($m) 'command: node "${CLAUDE_PROJECT_DIR}/' + $KIT_DIR + '/' + $m.Groups['rest'].Value.Trim() + '"' },
        [Text.RegularExpressions.RegexOptions]::Multiline
    )

    # (b) Everything else is prose the model reads and resolves with Read/Grep.
    #     A project-relative path works regardless of variable expansion.
    $text = $text.Replace('${CLAUDE_PLUGIN_ROOT}', $KIT_DIR)

    if ($text -ne $before) {
        Set-Content -LiteralPath $file.FullName -Value $text -NoNewline -Encoding UTF8
        $rewritten++
    }
}
Ok "rewrote $rewritten of $($skillFiles.Count) SKILL.md files"

# --- Plugin command namespace ----------------------------------------------
# Upstream tells the user (and the model) to re-run skills as `/agent365:<name>`.
# That namespace only exists once the plugin is installed. Project skills are
# invoked as `/<name>`, and CLIs other than Claude Code use trigger phrases and
# ignore it entirely. Applies to reference docs and validator messages too, not
# just SKILL.md -- the validators print these strings back to the user.

$nsFiles = Get-ChildItem -Path $KitPath -Recurse -File -Include '*.md', '*.js'
$nsRewritten = 0
$nsCount = 0
foreach ($file in $nsFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    $matches = [regex]::Matches($text, '/agent365:(?=[a-z])')
    if ($matches.Count -eq 0) { continue }
    $nsCount += $matches.Count
    Set-Content -LiteralPath $file.FullName -Value ($text -replace '/agent365:(?=[a-z])', '/') -NoNewline -Encoding UTF8
    $nsRewritten++
}
Ok "rewrote $nsCount /agent365: command references across $nsRewritten files"

# --- Targeted fix-ups -------------------------------------------------------
# Wording that only makes sense for a plugin install. Each fix-up MUST match, so
# an upstream rewording fails the build loudly instead of shipping nonsense.

$fixups = @(
    @{
        File = 'skills\a365-code-validator\SKILL.md'
        Find = @'
When running from the plugin source (Claude Code / marketplace plugin), use:

```bash
node .a365-kit/hooks/stop/validate-a365-code-validator.js
```

If the runtime cannot expand `.a365-kit`, run with the absolute plugin path:

```bash
node /path/to/agent365-skills/plugins/agent365/hooks/stop/validate-a365-code-validator.js
```
'@
        Replace = @'
Run it from the project root -- the path is relative to that root:

```bash
node .a365-kit/hooks/stop/validate-a365-code-validator.js
```

If the working directory is not the project root, use an absolute path:

```bash
node /path/to/your-project/.a365-kit/hooks/stop/validate-a365-code-validator.js
```
'@
    }
)

foreach ($fix in $fixups) {
    $target = Join-Path $KitPath $fix.File
    if (-not (Test-Path -LiteralPath $target)) { throw "Fix-up target missing: $($fix.File)" }
    $content = Get-Content -LiteralPath $target -Raw
    $find = $fix.Find -replace "`r`n", "`n"
    $normalized = $content -replace "`r`n", "`n"
    if ($normalized -notmatch [regex]::Escape($find)) {
        throw "Fix-up no longer matches in $($fix.File). Upstream changed -- update the fix-up in Build-Kit.ps1."
    }
    $normalized = $normalized.Replace($find, ($fix.Replace -replace "`r`n", "`n"))
    Set-Content -LiteralPath $target -Value $normalized -NoNewline -Encoding UTF8
    Ok "fix-up applied: $($fix.File)"
}

# ---------------------------------------------------------------------------
# 4. Patch path-guard.js
# ---------------------------------------------------------------------------
# Upstream refuses writes inside CLAUDE_PLUGIN_ROOT. That variable is unset in a
# drop-in install, which silently disables the guard. Repoint it at the kit folder
# so the skills still cannot modify their own instructions.

Step 'Patching path-guard.js for drop-in mode'

$guard = Join-Path $KitPath 'hooks\preToolUse\path-guard.js'
$guardText = Get-Content -LiteralPath $guard -Raw

$guardOld = @'
const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT
  ? safeRealpath(path.resolve(process.env.CLAUDE_PLUGIN_ROOT))
  : null;
'@
$guardNew = @'
// Agent 365 Onboarding Kit: in a drop-in install there is no plugin, so
// CLAUDE_PLUGIN_ROOT is unset and the "don't write into your own instructions"
// guard would silently disable itself. Fall back to the kit folder inside the
// project, which is the drop-in equivalent of the plugin root.
const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT
  ? safeRealpath(path.resolve(process.env.CLAUDE_PLUGIN_ROOT))
  : safeRealpath(path.join(projectRoot, '__KIT_DIR__'));
'@

$guardOldN = $guardOld -replace "`r`n", "`n"
$guardTextN = $guardText -replace "`r`n", "`n"
if ($guardTextN -notmatch [regex]::Escape($guardOldN)) {
    throw 'path-guard.js no longer matches the expected pluginRoot block. Update Build-Kit.ps1.'
}
$guardTextN = $guardTextN.Replace($guardOldN, ($guardNew -replace "`r`n", "`n").Replace('__KIT_DIR__', $KIT_DIR))
Set-Content -LiteralPath $guard -Value $guardTextN -NoNewline -Encoding UTF8
Ok 'path-guard.js now guards the kit folder'

# Also fix the message, which names an env var the user never set.
$guardTextN = Get-Content -LiteralPath $guard -Raw
$guardTextN = $guardTextN.Replace(
    '`Path guard: refusing to write inside CLAUDE_PLUGIN_ROOT (${pluginRoot}). ` +',
    '`Path guard: refusing to write inside the Agent 365 kit folder (${pluginRoot}). ` +')
Set-Content -LiteralPath $guard -Value $guardTextN -NoNewline -Encoding UTF8

# ---------------------------------------------------------------------------
# 5. Copilot instructions
# ---------------------------------------------------------------------------
# Staged under the kit folder rather than shipped at .github/copilot-instructions.md,
# because that file is commonly project-owned and must never be clobbered by an
# unzip. agent365-kit.ps1 -WireCopilot creates or appends it. Links are written
# relative to .github/, which is where the file ends up.

Step 'Staging GitHub Copilot instructions'

$copilotSrc = Join-Path $Upstream '.github\copilot-instructions.md'
if (Test-Path -LiteralPath $copilotSrc) {
    $copilot = Get-Content -LiteralPath $copilotSrc -Raw
    $copilot = $copilot.Replace('../plugins/agent365/', "../$KIT_DIR/")
    $copilot = $copilot.Replace('plugins/agent365/skills/', "$KIT_DIR/skills/")
    $copilot = $copilot.Replace('plugins/agent365/shared/', "$KIT_DIR/shared/")
    # Staged after the namespace pass above, so apply that rewrite here too.
    $copilot = $copilot -replace '/agent365:(?=[a-z])', '/'
    Set-Content -LiteralPath (Join-Path $KitPath 'copilot-instructions.md') -Value $copilot -NoNewline -Encoding UTF8
    Ok 'copilot-instructions.md staged (links repointed)'
} else {
    Warn 'upstream .github/copilot-instructions.md not found -- Copilot path will be unavailable'
}

# ---------------------------------------------------------------------------
# 6. Kit payload
# ---------------------------------------------------------------------------

Step 'Adding kit payload'

Copy-Item -Path (Join-Path $PayloadDir '.a365-kit\*') -Destination $KitPath -Recurse -Force
Copy-Item -Path (Join-Path $PayloadDir 'agent365-kit.ps1') -Destination $OutDir -Force
Copy-Item -Path (Join-Path $PayloadDir 'agent365-kit.sh')  -Destination $OutDir -Force

$readmeSrc = Join-Path $PayloadDir 'AGENT365-KIT-README.md'
if (Test-Path -LiteralPath $readmeSrc) {
    Copy-Item -Path $readmeSrc -Destination $OutDir -Force
    Ok 'AGENT365-KIT-README.md'
}
Ok 'doctor.js, kit-version.js, settings-fragment.json, launchers'

$manifest = [ordered]@{
    kitVersion      = $KitVersion
    upstreamRepo    = 'microsoft/agent365-skills'
    upstreamVersion = $UpstreamVersion
    upstreamCommit  = $UpstreamCommit
    builtUtc        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    skills          = @(Get-ChildItem -Path (Join-Path $KitPath 'skills') -Directory | ForEach-Object { $_.Name })
}
$manifest | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $KitPath 'KIT-VERSION.json') -Encoding UTF8
Ok 'KIT-VERSION.json'

# ---------------------------------------------------------------------------
# 7. Discovery copies
# ---------------------------------------------------------------------------
# Each CLI family looks in a different place. The skill files are byte-identical
# in all three locations because every internal reference points at .a365-kit/.

Step 'Creating per-CLI discovery copies'

$discoveryTargets = @(
    @{ Path = '.claude\skills'; For = 'Claude Code' }
    @{ Path = '.agents\skills'; For = 'VS Code agent mode / gh skill' }
)

foreach ($target in $discoveryTargets) {
    $dest = Join-Path $OutDir $target.Path
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Path (Join-Path $KitPath 'skills\*') -Destination $dest -Recurse -Force
    Ok "$($target.Path)  ->  $($target.For)"
}

# ---------------------------------------------------------------------------
# 8. Verify
# ---------------------------------------------------------------------------

Step 'Verifying build'

$problems = @()

# (a) No leftover ${CLAUDE_PLUGIN_ROOT} PATH TOKENS anywhere in the output.
#     A bare `process.env.CLAUDE_PLUGIN_ROOT` read is fine and deliberate -- path-guard.js
#     still honours the variable when someone does load the skills as a plugin. It is the
#     ${...} interpolation form that silently resolves to nothing in a drop-in install.
$leftovers = Get-ChildItem -Path $OutDir -Recurse -File -Include '*.md', '*.js', '*.json' |
    Select-String -Pattern '${CLAUDE_PLUGIN_ROOT}' -SimpleMatch
if ($leftovers) {
    foreach ($hit in $leftovers) {
        $problems += "leftover `${CLAUDE_PLUGIN_ROOT} token: $($hit.Path):$($hit.LineNumber)"
    }
} else {
    Ok 'no ${CLAUDE_PLUGIN_ROOT} path tokens remain'
}

# (a2) No plugin command namespace remains.
$nsLeft = Get-ChildItem -Path $OutDir -Recurse -File -Include '*.md', '*.js' |
    Select-String -Pattern '/agent365:' -SimpleMatch
if ($nsLeft) {
    foreach ($hit in $nsLeft) { $problems += "leftover /agent365: namespace: $($hit.Path):$($hit.LineNumber)" }
} else {
    Ok 'no /agent365: plugin command references remain'
}

# (b) Every .a365-kit/... path referenced by a skill actually exists.
$refPattern = [regex]::Escape($KIT_DIR) + '/[A-Za-z0-9_./-]+'
$checked = 0
$badRefs = @()
foreach ($file in (Get-ChildItem -Path (Join-Path $KitPath 'skills') -Filter 'SKILL.md' -Recurse)) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($m in [regex]::Matches($text, $refPattern)) {
        $rel = $m.Value.TrimEnd('.', ',', ')', '`')
        # Only verify concrete file references, not directory prose.
        if ($rel -notmatch '\.(md|js|json)$') { continue }
        $checked++
        $abs = Join-Path $OutDir ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $abs)) {
            $badRefs += "$($file.Name) -> $rel"
        }
    }
}
$badRefs = $badRefs | Select-Object -Unique
if ($badRefs) {
    foreach ($b in $badRefs) { $problems += "broken reference: $b" }
} else {
    Ok "all $checked skill file references resolve"
}

# (c) Every JS file parses.
$jsFiles = Get-ChildItem -Path $KitPath -Recurse -File -Filter '*.js'
foreach ($js in $jsFiles) {
    & node --check $js.FullName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $problems += "JS syntax error: $($js.FullName)" }
}
Ok "$($jsFiles.Count) JS files parse cleanly"

# (d) Discovery copies match the canonical set.
$canonicalNames = (Get-ChildItem -Path (Join-Path $KitPath 'skills') -Directory).Name | Sort-Object
foreach ($target in $discoveryTargets) {
    $names = (Get-ChildItem -Path (Join-Path $OutDir $target.Path) -Directory).Name | Sort-Object
    if (Compare-Object $canonicalNames $names) {
        $problems += "discovery copy out of sync: $($target.Path)"
    }
}
Ok 'discovery copies match canonical skills'

# (e) Hook commands are absolute and quoted.
$hookCmds = Select-String -Path (Join-Path $KitPath 'skills\*\SKILL.md') -Pattern 'command:\s*node'
foreach ($hit in $hookCmds) {
    if ($hit.Line -notmatch '\$\{CLAUDE_PROJECT_DIR\}') {
        $problems += "hook command not repointed: $($hit.Path):$($hit.LineNumber)"
    }
}
Ok "$($hookCmds.Count) hook commands repointed to `${CLAUDE_PROJECT_DIR}"

if ($problems.Count -gt 0) {
    Write-Host ''
    Fail "$($problems.Count) problem(s):"
    $problems | ForEach-Object { Write-Host "           $_" -ForegroundColor Red }
    throw 'Build verification failed.'
}

# ---------------------------------------------------------------------------
# 9. Package
# ---------------------------------------------------------------------------

if ($Zip) {
    Step 'Packaging'
    $zipName = "agent365-onboarding-kit-v$KitVersion.zip"
    $zipPath = Join-Path $RepoRoot $zipName
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    # -Path with \* keeps the archive rooted at the payload, not at dist/.
    Compress-Archive -Path (Join-Path $OutDir '*') -DestinationPath $zipPath -Force
    $sizeKb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB)
    Ok "$zipName ($sizeKb KB)"
}

Write-Host ''
Write-Host 'Build succeeded.' -ForegroundColor Green
Info "kit v$KitVersion  |  upstream agent365-skills v$UpstreamVersion ($UpstreamCommit)"
Info "output: $OutDir"
Write-Host ''

}
finally {
    if ($TempClone -and (Test-Path -LiteralPath $TempClone)) {
        Remove-Item -LiteralPath $TempClone -Recurse -Force -ErrorAction SilentlyContinue
    }
}
