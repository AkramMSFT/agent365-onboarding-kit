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

.PARAMETER UpdateSource
    Where the launchers' -Update / --update fetch the kit from, baked into KIT-VERSION.json as
    the build default. Override it when you host the kit yourself -- an internal GitHub, an
    artifact server, or a file share (a path works as well as a URL). Users can still override
    per project with `agent365-kit.ps1 -SetUpdateSource`, per shell with A365_KIT_UPDATE_SOURCE,
    or per call with -UpdateFrom.

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
    [string] $KitVersion,
    [string] $UpdateSource = 'https://github.com/AkramMSFT/agent365-onboarding-kit/releases/latest/download/agent365-onboarding-kit-latest.zip'
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
        # BUG FIX, not a path rewrite -- disclosed in NOTICE.md section 8.
        # Upstream detects Python only via pyproject.toml. The skills' own stack detection
        # and every sibling validator also accept requirements.txt, so a requirements.txt-
        # only Python project falls through to the Node.js default and fails eight
        # TypeScript checks that do not apply. As a Claude Code stop hook that blocks the
        # session from ending, which is a bad outcome for a false negative.
        File = 'hooks\stop\validate-make-ai-teammate.js'
        Find = @'
const hasPyproject  = fs.existsSync(path.join(cwd, 'pyproject.toml'));
'@
        Replace = @'
// Agent 365 Onboarding Kit fix-up: upstream keys Python detection on pyproject.toml
// only, but the skills' stack detection and every sibling validator also accept
// requirements.txt. See NOTICE.md in the kit repository.
const hasPyproject  = fs.existsSync(path.join(cwd, 'pyproject.toml'))
                   || fs.existsSync(path.join(cwd, 'requirements.txt'));
'@
    }
    @{
        # BUG FIX -- NOTICE.md section 8. Upstream only looks for agent.py at the project
        # root; existing Python projects commonly keep it under src/. The skill itself
        # adapts to that layout, the validator did not.
        File = 'hooks\stop\validate-make-ai-teammate.js'
        Find = @'
  // Check 2: agent.py — agent interface implementation
  const agentFile = path.join(cwd, 'agent.py');
  if (fs.existsSync(agentFile)) {
'@
        Replace = @'
  // Check 2: agent.py — agent interface implementation
  // Kit fix-up: accept agent.py anywhere in the scanned tree (e.g. src/agent.py),
  // not only at the project root. See NOTICE.md in the kit repository.
  const agentFileAtRoot = path.join(cwd, 'agent.py');
  const agentFile = fs.existsSync(agentFileAtRoot)
    ? agentFileAtRoot
    : pyFiles.find(f => path.basename(f) === 'agent.py');
  if (agentFile && fs.existsSync(agentFile)) {
'@
    }
    @{
        # BUG FIX -- NOTICE.md section 8. Upstream reads dependencies from pyproject.toml
        # only, with underscore-only package names. requirements.txt projects were never
        # checked at all, and after the language fix-up above they would be checked
        # against a file that does not exist. pip treats hyphen and underscore forms as
        # the same package, so the comparison normalises both sides.
        File = 'hooks\stop\validate-make-ai-teammate.js'
        Find = @'
  // Check 4: Required packages in pyproject.toml — tooling/observability added by separate skills
  if (hasPyproject) {
    const required = [
      'microsoft_agents_a365_notifications',
      'microsoft_agents_a365_runtime',
      'microsoft-agents-hosting-aiohttp',
    ];
    for (const pkg of required) {
      if (!fileContains(path.join(cwd, 'pyproject.toml'), pkg)) {
        issues.push(`${pkg} not found in pyproject.toml dependencies`);
      }
    }
  }
'@
        Replace = @'
  // Check 4: Required packages — tooling/observability added by separate skills
  // Kit fix-up: read pyproject.toml or requirements.txt, whichever exists, and accept
  // hyphen/underscore package-name forms (pip treats them as equivalent).
  // See NOTICE.md in the kit repository.
  const depFile = ['pyproject.toml', 'requirements.txt']
    .map(f => path.join(cwd, f))
    .find(f => fs.existsSync(f));
  if (depFile) {
    const depText = fs.readFileSync(depFile, 'utf8').toLowerCase().replace(/_/g, '-');
    const required = [
      'microsoft_agents_a365_notifications',
      'microsoft_agents_a365_runtime',
      'microsoft-agents-hosting-aiohttp',
    ];
    for (const pkg of required) {
      if (!depText.includes(pkg.toLowerCase().replace(/_/g, '-'))) {
        issues.push(`${pkg} not found in ${path.basename(depFile)} dependencies`);
      }
    }
  }
'@
    }
    @{
        # BUG FIX -- NOTICE.md section 9. Node.js branch: the check tests only that the
        # key EXISTS. The a365 CLI stamps ENABLE_A365_OBSERVABILITY_EXPORTER=false, and
        # instrument-observability deliberately preserves an existing value, so an agent
        # that exports nothing passes validation as fully instrumented.
        File = 'hooks\stop\validate-instrument-observability.js'
        Find = @'
  const hasEnvConfig = envFiles.some(f =>
    fileContains(f, 'ENABLE_A365_OBSERVABILITY_EXPORTER'));
  if (!hasEnvConfig) {
    issues.push('.env / .env.example does not contain ENABLE_A365_OBSERVABILITY_EXPORTER');
  }
'@
        Replace = @'
  const hasEnvConfig = envFiles.some(f =>
    fileContains(f, 'ENABLE_A365_OBSERVABILITY_EXPORTER'));
  if (!hasEnvConfig) {
    issues.push('.env / .env.example does not contain ENABLE_A365_OBSERVABILITY_EXPORTER');
  } else if (!envFiles.some(f => { try { return /ENABLE_A365_OBSERVABILITY_EXPORTER\s*=\s*true/i.test(fs.readFileSync(f, 'utf8')); } catch { return false; } })) {
    // Kit fix-up: the value must be true or nothing is ever exported.
    issues.push('ENABLE_A365_OBSERVABILITY_EXPORTER is present but not "true" -- the agent is instrumented but exports nothing; set it to true and restart');
  }
'@
    }
    @{
        # BUG FIX -- NOTICE.md section 9. Python branch: same defect.
        File = 'hooks\stop\validate-instrument-observability.js'
        Find = @'
  const hasEnvConfig = envFiles.some(f =>
    fileContains(f, 'ENABLE_A365_OBSERVABILITY_EXPORTER'));
  if (!hasEnvConfig) {
    issues.push('.env does not contain ENABLE_A365_OBSERVABILITY_EXPORTER');
  }
'@
        Replace = @'
  const hasEnvConfig = envFiles.some(f =>
    fileContains(f, 'ENABLE_A365_OBSERVABILITY_EXPORTER'));
  if (!hasEnvConfig) {
    issues.push('.env does not contain ENABLE_A365_OBSERVABILITY_EXPORTER');
  } else if (!envFiles.some(f => { try { return /ENABLE_A365_OBSERVABILITY_EXPORTER\s*=\s*true/i.test(fs.readFileSync(f, 'utf8')); } catch { return false; } })) {
    // Kit fix-up: the value must be true or nothing is ever exported.
    issues.push('ENABLE_A365_OBSERVABILITY_EXPORTER is present but not "true" -- the agent is instrumented but exports nothing; set it to true and restart');
  }
'@
    }
    @{
        # BEHAVIOUR FIX -- NOTICE.md section 10. Invariant 1 tells the skill to preserve
        # an existing ENABLE_A365_OBSERVABILITY_EXPORTER. The a365 CLI writes it as
        # false, so "add observability to my agent" reliably lands an agent that traces
        # every turn and exports none of it. Invariant 3 already has the skill correct
        # the equivalent .NET value; this makes Node.js and Python consistent with it.
        File = 'skills\instrument-observability\SKILL.md'
        Find = @'
1. **Preserve existing values.** If `Agent365Observability` (.NET) or
   `ENABLE_A365_OBSERVABILITY_EXPORTER` (Node.js / Python) already exists, do not
   overwrite. Add only missing keys.
'@
        Replace = @'
1. **Preserve existing values, with one exception.** If `Agent365Observability`
   (.NET) or `ENABLE_A365_OBSERVABILITY_EXPORTER` (Node.js / Python) already
   exists, do not overwrite. Add only missing keys.

   **Exception -- the exporter switch.** `ENABLE_A365_OBSERVABILITY_EXPORTER`
   (Node.js / Python) is the one value you DO correct. `a365 setup` writes it as
   `false`. Preserving that leaves the agent instrumented but silent: it builds a
   span for every turn and exports none of them, and the Agent 365 Activity view
   stays empty with nothing anywhere reporting a fault. Set it to `true`, and say
   so in your summary. This mirrors invariant 3, which already has you correct the
   equivalent .NET value for the same reason.
'@
    }
    @{
        # BEHAVIOUR FIX -- NOTICE.md section 10. The other half of the pair: rule 6 had
        # the skill report the disabled exporter instead of fixing it, and one line in a
        # long completion summary is easy to miss.
        File = 'skills\instrument-observability\SKILL.md'
        Find = @'
"instrumented but
     disabled; set `ENABLE_A365_OBSERVABILITY_EXPORTER=true` to start exporting".
'@
        Replace = @'
"the exporter was off; I set
     `ENABLE_A365_OBSERVABILITY_EXPORTER=true` for you -- restart the agent for
     it to take effect".
'@
    }
    @{
        # BEHAVIOUR FIX -- NOTICE.md section 10. Phase 9 told the user to go and enable
        # the exporter, which now contradicts the skill having already done it.
        File = 'skills\instrument-observability\SKILL.md'
        Find = @'
   1. Enable exporting when ready for production:
'@
        Replace = @'
   1. Confirm the exporter is still on -- this skill sets it, but a later
      `a365 setup` run can reset it to false:
'@
    }
    @{
        # BUG FIX -- NOTICE.md section 11. The OBO sample passes AgenticTokenCache's
        # async getter as a365_token_resolver, but the exporter calls the resolver
        # synchronously from its batch-export thread. It gets back an un-awaited
        # coroutine, which is truthy, so the "no token" guard passes and it sends
        # "Bearer <coroutine object ...>". Upstream's own kwarg table documents this
        # parameter as a SYNC callable, and its S2S sample passes one correctly.
        File = 'skills\instrument-observability\references\python-observability.md'
        Find = @'
_token_cache = AgenticTokenCache()

use_microsoft_opentelemetry(
    enable_a365=True,
    a365_enable_observability_exporter=True,   # REQUIRED in 1.0+ to actually export spans
    a365_token_resolver=_token_cache.get_observability_token,
)
'@
        Replace = @'
import asyncio

_token_cache = AgenticTokenCache()

# a365_token_resolver must be a SYNC callable. AgenticTokenCache exposes only an
# async getter, so bridge onto the host loop rather than passing it directly:
# the exporter calls the resolver from its own export thread, so passing the
# coroutine function hands it an un-awaited coroutine. That object is truthy, so
# the exporter's "no token" guard does not catch it and it sends
# "Bearer <coroutine object ...>", which the service rejects with
# {"code":"EndpointInvalid","message":"Tenant id  is invalid."} -- note the blank
# tenant: the value is unreadable, not missing from your config.
HOST_LOOP: asyncio.AbstractEventLoop | None = None


def _observability_token(agent_id: str, tenant_id: str) -> str | None:
    if HOST_LOOP is None or not HOST_LOOP.is_running():
        return None
    try:
        return asyncio.run_coroutine_threadsafe(
            _token_cache.get_observability_token(agent_id, tenant_id), HOST_LOOP
        ).result(timeout=15)
    except Exception:
        return None   # a telemetry failure must never cost a turn


use_microsoft_opentelemetry(
    enable_a365=True,
    a365_enable_observability_exporter=True,   # REQUIRED in 1.0+ to actually export spans
    a365_token_resolver=_observability_token,
)
```

`HOST_LOOP` has to be set from code that runs **on** the loop. The simplest place is the
per-turn handler this skill already instruments — the same function that opens
`InvokeAgentScope`. Reassigning it each turn is cheap and idempotent:

```python
import asyncio
import src.agent as core          # the module holding HOST_LOOP

async def on_message(context, state):
    core.HOST_LOOP = asyncio.get_running_loop()
    with InvokeAgentScope.start(...):
        ...
```

If the host has an async startup coroutine, setting it once there works equally well:

```python
async def start_server() -> None:
    core.HOST_LOOP = asyncio.get_running_loop()
```

Leaving `HOST_LOOP` unset does not fail silently: the exporter logs
`No token resolved for agent ...; dropping chunk N of M` at ERROR on every export.
'@
    }
    @{
        # BUG FIX -- NOTICE.md section 11. SKILL.md is read before any reference doc, so
        # fixing only python-observability.md leaves the model with a contradiction and
        # the broken wiring stated first. Same defect, same fix, stated where it is read.
        File = 'skills\instrument-observability\SKILL.md'
        Find = @'
Wire `a365_token_resolver` to `AgenticTokenCache().get_observability_token` from `microsoft.opentelemetry.a365.hosting.token_cache_helpers` (or a custom resolver reading from `token_cache.py`).
'@
        Replace = @'
Wire `a365_token_resolver` to a **synchronous** callable. Do NOT pass `AgenticTokenCache().get_observability_token` directly: it is `async def`, and the exporter calls the resolver synchronously from its own batch-export thread, so it receives an un-awaited coroutine. A coroutine object is truthy, so the exporter's "no token" guard does not catch it and it sends the literal string `Bearer <coroutine object ...>`; the service then rejects every export with `EndpointInvalid` / "Tenant id  is invalid" (the blank tenant means unreadable, not missing from config). Use the `run_coroutine_threadsafe` bridge shown in the OBO section of `.a365-kit/skills/instrument-observability/references/python-observability.md`, capturing the running loop in the same per-turn handler you wrap with `InvokeAgentScope`. A custom resolver reading from `token_cache.py` is also fine as long as it is sync.
'@
    }
    @{
        # BUG FIX -- NOTICE.md section 11. Catches the async resolver in code that is
        # already written, including agents onboarded before the reference was fixed.
        File = 'hooks\stop\validate-instrument-observability.js'
        Find = @'
    const hasS2SEndpoint = anyFileContains(pyFiles, 'use_s2s_endpoint') ||
                           anyFileContains(pyFiles, 'use_microsoft_opentelemetry');
    if (!hasS2SEndpoint) {
      issues.push('S2S: use_microsoft_opentelemetry() or use_s2s_endpoint not found in observability configuration');
    }
  }
'@
        Replace = @'
    const hasS2SEndpoint = anyFileContains(pyFiles, 'use_s2s_endpoint') ||
                           anyFileContains(pyFiles, 'use_microsoft_opentelemetry');
    if (!hasS2SEndpoint) {
      issues.push('S2S: use_microsoft_opentelemetry() or use_s2s_endpoint not found in observability configuration');
    }
  }

  // Kit fix-up: a365_token_resolver must be a SYNC callable. Wiring it straight to
  // AgenticTokenCache.get_observability_token (async def) hands the exporter an
  // un-awaited coroutine; a coroutine is truthy, so the exporter's own "no token"
  // guard misses it and it sends "Bearer <coroutine object ...>".
  const asyncResolverFiles = pyFiles.filter(f => {
    try {
      return /a365_token_resolver\s*=\s*[\w.]*\bget_observability_token\b/
        .test(fs.readFileSync(f, 'utf8'));
    } catch {
      return false;
    }
  });
  if (asyncResolverFiles.length) {
    issues.push('a365_token_resolver is wired directly to the async get_observability_token (' +
      asyncResolverFiles.map(f => path.basename(f)).join(', ') +
      ') -- the exporter calls it synchronously, so every export is rejected with ' +
      'EndpointInvalid / "Tenant id  is invalid". Use the run_coroutine_threadsafe bridge ' +
      'in references/python-observability.md (OBO section)');
  }
'@
    }
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
    updateSource    = $UpdateSource
    skills          = @(Get-ChildItem -Path (Join-Path $KitPath 'skills') -Directory | ForEach-Object { $_.Name })
    addons          = @(if (Test-Path -LiteralPath (Join-Path $KitPath 'addons')) {
                          Get-ChildItem -Path (Join-Path $KitPath 'addons') -Directory | ForEach-Object { $_.Name } })
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
    # Kit-authored add-ons live in .a365-kit/addons/ (from payload/), separate from the
    # seven upstream skills so provenance stays clear, but they are discovered the same way.
    $addonsPath = Join-Path $KitPath 'addons'
    if (Test-Path -LiteralPath $addonsPath) {
        Copy-Item -Path (Join-Path $addonsPath '*') -Destination $dest -Recurse -Force
    }
    Ok "$($target.Path)  ->  $($target.For)"
}
$addonNames = @()
if (Test-Path -LiteralPath (Join-Path $KitPath 'addons')) {
    $addonNames = @(Get-ChildItem -Path (Join-Path $KitPath 'addons') -Directory | ForEach-Object { $_.Name })
    Ok "add-ons included: $($addonNames -join ', ')"
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
$skillMdRoots = @((Join-Path $KitPath 'skills'))
if (Test-Path -LiteralPath (Join-Path $KitPath 'addons')) { $skillMdRoots += (Join-Path $KitPath 'addons') }
foreach ($file in ($skillMdRoots | ForEach-Object { Get-ChildItem -Path $_ -Filter 'SKILL.md' -Recurse })) {
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

# (d) Discovery copies match the canonical set: the seven upstream skills plus kit add-ons.
$canonicalNames = @((Get-ChildItem -Path (Join-Path $KitPath 'skills') -Directory).Name)
if (Test-Path -LiteralPath (Join-Path $KitPath 'addons')) {
    $canonicalNames += @((Get-ChildItem -Path (Join-Path $KitPath 'addons') -Directory).Name)
}
$canonicalNames = $canonicalNames | Sort-Object
foreach ($target in $discoveryTargets) {
    $names = (Get-ChildItem -Path (Join-Path $OutDir $target.Path) -Directory).Name | Sort-Object
    if (Compare-Object $canonicalNames $names) {
        $problems += "discovery copy out of sync: $($target.Path)"
    }
}
Ok "discovery copies match canonical skills + add-ons ($($canonicalNames.Count) total)"

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
