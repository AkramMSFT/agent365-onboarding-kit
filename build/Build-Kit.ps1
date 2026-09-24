<#
.SYNOPSIS
    Builds the distributable Agent 365 Onboarding Kit from upstream microsoft/agent365-skills.

.DESCRIPTION
    Turns Microsoft's agent365-skills plugin into a drop-in folder that works with any
    agentic CLI, with no plugin install and no marketplace step.

    What it produces in -OutDir:

        .a365-kit/                  canonical content: skills, shared docs, hook validators
        .claude/skills/             discovery copy for Claude Code
        .agents/skills/             discovery copy for VS Code agent mode / gh skill
        agent365-kit.ps1|.sh        prereq check + per-CLI activation steps
        AGENT365-KIT-README.md      what to do after extracting

    The upstream skills reference sibling files through ${CLAUDE_PLUGIN_ROOT}, which only
    resolves when the skills are loaded as a plugin. Because .a365-kit/ mirrors the upstream
    layout exactly (skills/, shared/, hooks/), rewriting that token to the relative path
    ".a365-kit" fixes every in-body reference in one substitution. Hook commands are the
    exception. Claude Code executes them, so they use ${CLAUDE_PROJECT_DIR}, which it
    expands reliably, quoted to survive spaces in the path.

.PARAMETER UpstreamPath
    Path to an existing git clone of microsoft/agent365-skills. If omitted, the script
    clones upstream into a temp folder and removes it afterwards.

.PARAMETER UpstreamRef
    Branch, tag or commit to build when -UpstreamPath is not supplied. Default: main.
    A branch or tag is shallow-cloned; a commit (7 to 40 hex characters) is checked out
    from a full clone.

.PARAMETER OutDir
    Output directory. Default: <repo>/kit. BUNDLE-MANIFEST.json and SHA256SUMS.txt are
    written at the repo root only when the output is <repo>/kit.

.PARAMETER Zip
    Also produce agent365-onboarding-kit-v<version>.zip (kit only) at the repo root and,
    when the output is <repo>/kit, agent365-onboarding-bundle-v<version>.zip (kit,
    examples, tools and docs).

.PARAMETER KitVersion
    Version stamp for this kit, as MAJOR.MINOR.PATCH. Default: read from build/kit.version.

.PARAMETER BuiltUtc
    Timestamp written to KIT-VERSION.json. Default: now. CI passes the committed value so a
    rebuild of the pinned upstream commit can be compared byte for byte with kit/.

.PARAMETER UpdateSource
    Where the launchers' -Update / --update fetch the kit from, baked into KIT-VERSION.json as
    the build default. Override it when you host the kit yourself: an internal GitHub, an
    artifact server, or a file share (a path works as well as a URL). Users can still override
    per project with `agent365-kit.ps1 -SetUpdateSource`, per shell with A365_KIT_UPDATE_SOURCE,
    or per call with -UpdateFrom.

.EXAMPLE
    .\build\Build-Kit.ps1 -UpstreamPath C:\src\agent365-skills

.EXAMPLE
    .\build\Build-Kit.ps1 -Zip
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $UpstreamPath,
    [string] $UpstreamRef = 'main',
    [string] $OutDir,
    [switch] $Zip,
    [string] $KitVersion,
    [string] $BuiltUtc,
    [string] $UpdateSource = 'https://github.com/AkramMSFT/agent365-sdk-onboarding-experience/releases/latest/download/agent365-onboarding-kit-latest.zip'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$PayloadDir  = Join-Path $RepoRoot 'payload'
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'kit' }

$KIT_DIR = '.a365-kit'   # Canonical folder name inside the user's project.

function Step { param([string] $T) Write-Host ''; Write-Host "==> $T" -ForegroundColor Cyan }
function Ok   { param([string] $T) Write-Host "    [ok]   $T" -ForegroundColor Green }
function Info { param([string] $T) Write-Host "    $T" -ForegroundColor Gray }
function Warn { param([string] $T) Write-Host "    [warn] $T" -ForegroundColor Yellow }
function Fail { param([string] $T) Write-Host "    [FAIL] $T" -ForegroundColor Red }

if (-not $KitVersion) {
    $versionFile = Join-Path $RepoRoot 'build\kit.version'
    if (-not (Test-Path -LiteralPath $versionFile)) { throw 'build/kit.version not found; the kit version must be explicit.' }
    $KitVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim()
}
if ($KitVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Kit version '$KitVersion' is not MAJOR.MINOR.PATCH." }
if (-not $BuiltUtc) { $BuiltUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

Write-Host ''
Write-Host 'Agent 365 Onboarding Kit -- build' -ForegroundColor White
Write-Host '=================================' -ForegroundColor DarkGray

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
    # core.longpaths guards against the Windows MAX_PATH limit, which other Agent 365
    # repositories have hit.
    if ($UpstreamRef -match '^[0-9a-f]{7,40}$') {
        Info "Cloning upstream and checking out commit $UpstreamRef into $TempClone"
        & git -c core.longpaths=true clone --quiet https://github.com/microsoft/agent365-skills.git $TempClone 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)" }
        & git -C $TempClone -c advice.detachedHead=false checkout --quiet $UpstreamRef 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "upstream commit $UpstreamRef not found" }
    } else {
        Info "Shallow-cloning $UpstreamRef into $TempClone"
        & git -c core.longpaths=true clone --depth 1 --branch $UpstreamRef `
            https://github.com/microsoft/agent365-skills.git $TempClone 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)" }
    }
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
$UpstreamCommit = (& git -C $Upstream rev-parse --short=7 HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $UpstreamCommit) { throw "Cannot read the upstream commit from $Upstream; it must be a git checkout." }

Ok "upstream agent365-skills v$UpstreamVersion ($UpstreamCommit)"
Ok "building kit v$KitVersion"

try {

Step "Staging canonical content into $KIT_DIR/"

if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$KitPath = Join-Path $OutDir $KIT_DIR
New-Item -ItemType Directory -Force -Path $KitPath | Out-Null

foreach ($dir in @('skills', 'shared', 'hooks')) {
    Copy-Item -LiteralPath (Join-Path $PluginRoot $dir) -Destination $KitPath -Recurse
    Ok "copied $dir/"
}

# Upstream commits some files with CRLF, and a Windows checkout of payload/ may too.
# Normalising to LF keeps the output, and so the manifest hashes, independent of the
# platform that built it.
function Convert-ToLf {
    param([string]$Root, [string]$What)
    $count = 0
    foreach ($tf in Get-ChildItem -Path $Root -Recurse -File -Include '*.md', '*.js', '*.mjs', '*.json', '*.sh', '*.ps1', '*.py', '*.ts', '*.cs', '*.yml', '*.yaml', '*.txt') {
        $bytes = [IO.File]::ReadAllBytes($tf.FullName)
        $text  = [Text.Encoding]::UTF8.GetString($bytes)
        if ($text.Contains("`r`n")) {
            [IO.File]::WriteAllText($tf.FullName, $text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
            $count++
        }
    }
    if ($count) { Ok "normalised $count $What file(s) to LF" }
}

Convert-ToLf -Root $KitPath -What 'staged'

Step 'Rewriting ${CLAUDE_PLUGIN_ROOT} references'

$skillFiles = Get-ChildItem -Path (Join-Path $KitPath 'skills') -Filter 'SKILL.md' -Recurse
$rewritten = 0

foreach ($file in $skillFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    $before = $text

    # Hook commands are run by the host and need an absolute path. Claude Code expands
    # ${CLAUDE_PROJECT_DIR}; the quotes survive spaces in the path.
    $text = [regex]::Replace(
        $text,
        'command:\s*node\s+\$\{CLAUDE_PLUGIN_ROOT\}/(?<rest>[^\r\n]+?)(?=\s*$)',
        { param($m) 'command: node "${CLAUDE_PROJECT_DIR}/' + $KIT_DIR + '/' + $m.Groups['rest'].Value.Trim() + '"' },
        [Text.RegularExpressions.RegexOptions]::Multiline
    )

    # Everything else is prose resolved with Read/Grep, where a project-relative path
    # works without variable expansion.
    $text = $text.Replace('${CLAUDE_PLUGIN_ROOT}', $KIT_DIR)

    if ($text -ne $before) {
        Set-Content -LiteralPath $file.FullName -Value $text -NoNewline -Encoding UTF8
        $rewritten++
    }
}
Ok "rewrote $rewritten of $($skillFiles.Count) SKILL.md files"

# Plugin command namespace. Upstream refers to skills as /agent365:<name>, which exists
# only when the plugin is installed; project skills are invoked as /<name>. Reference
# docs and validator messages are rewritten too, because the validators print them.

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

# Packaging fix-ups. Each Find must match upstream exactly, so an upstream rewording
# fails the build instead of shipping a half-patched file.

$fixups = @(
    @{
        # Python is detected by pyproject.toml only, so a requirements.txt project fails the
        # Node.js checks. NOTICE.md section 8.
        File = 'hooks\stop\validate-make-ai-teammate.js'
        Find = @'
const hasPyproject  = fs.existsSync(path.join(cwd, 'pyproject.toml'));
'@
        Replace = @'
// Accept requirements.txt as well as pyproject.toml, as the other validators do.
// Changed by the Agent 365 Onboarding Kit; see its NOTICE.md, section 8.
const hasPyproject  = fs.existsSync(path.join(cwd, 'pyproject.toml'))
                   || fs.existsSync(path.join(cwd, 'requirements.txt'));
'@
    }
    @{
        # agent.py is accepted only at the project root, not under src/. NOTICE.md section 8.
        File = 'hooks\stop\validate-make-ai-teammate.js'
        Find = @'
  // Check 2: agent.py — agent interface implementation
  const agentFile = path.join(cwd, 'agent.py');
  if (fs.existsSync(agentFile)) {
'@
        Replace = @'
  // Check 2: agent.py — agent interface implementation
  // Accept agent.py anywhere in the scanned tree, such as src/agent.py.
  // Changed by the Agent 365 Onboarding Kit; see its NOTICE.md, section 8.
  const agentFileAtRoot = path.join(cwd, 'agent.py');
  const agentFile = fs.existsSync(agentFileAtRoot)
    ? agentFileAtRoot
    : pyFiles.find(f => path.basename(f) === 'agent.py');
  if (agentFile && fs.existsSync(agentFile)) {
'@
    }
    @{
        # Dependencies are read from pyproject.toml only and compared by underscore name,
        # although pip treats hyphen and underscore as equal. NOTICE.md section 8.
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
  // Read pyproject.toml or requirements.txt, and compare package names the way pip
  // does, with hyphens and underscores equal. Changed by the Agent 365 Onboarding Kit;
  // see its NOTICE.md, section 8.
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
        # Invariant 1 preserves the exporter switch that a365 setup writes as false, so the
        # agent exports nothing. NOTICE.md section 10.
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
        # Rule 6 reports the disabled exporter instead of fixing it. NOTICE.md section 10.
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
        # Phase 9 tells the user to enable an exporter the skill has already enabled.
        # NOTICE.md section 10.
        File = 'skills\instrument-observability\SKILL.md'
        Find = @'
   1. Enable exporting when ready for production:
'@
        Replace = @'
   1. Confirm the exporter is still on. This skill sets it, but a later
      `a365 setup` run can reset it to false:
'@
    }
    @{
        # The OBO sample passes an async getter as the synchronous a365_token_resolver, so
        # every export sends a coroutine as the bearer token. NOTICE.md section 11.
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

# The exporter calls a365_token_resolver synchronously from its own thread, and
# AgenticTokenCache only has an async getter, so run it on the host loop. Passing the
# coroutine function directly sends "Bearer <coroutine object ...>", which the service
# rejects as "Tenant id  is invalid." even though the tenant is configured correctly.
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
        # SKILL.md states the same async resolver wiring and is read before the reference
        # doc. NOTICE.md section 11.
        File = 'skills\instrument-observability\SKILL.md'
        Find = @'
Wire `a365_token_resolver` to `AgenticTokenCache().get_observability_token` from `microsoft.opentelemetry.a365.hosting.token_cache_helpers` (or a custom resolver reading from `token_cache.py`).
'@
        Replace = @'
Wire `a365_token_resolver` to a **synchronous** callable. Do NOT pass `AgenticTokenCache().get_observability_token` directly: it is `async def`, and the exporter calls the resolver synchronously from its own batch-export thread, so it receives an un-awaited coroutine. A coroutine object is truthy, so the exporter's "no token" guard does not catch it and it sends the literal string `Bearer <coroutine object ...>`; the service then rejects every export with `EndpointInvalid` / "Tenant id  is invalid" (the blank tenant means unreadable, not missing from config). Use the `run_coroutine_threadsafe` bridge shown in the OBO section of `.a365-kit/skills/instrument-observability/references/python-observability.md`, capturing the running loop in the same per-turn handler you wrap with `InvokeAgentScope`. A custom resolver reading from `token_cache.py` is also fine as long as it is sync.
'@
    }
    @{
        # The validator does not catch the async resolver in code already written.
        # NOTICE.md section 11.
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

  // a365_token_resolver is called synchronously. Wiring it to the async
  // get_observability_token sends "Bearer <coroutine object ...>", which the exporter's
  // empty-token check misses because a coroutine is truthy. See NOTICE.md, section 11.
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
        # SKILL.md spells the Node.js API RefreshObservabilityToken, which is undefined;
        # both occurrences become refreshObservabilityToken. NOTICE.md section 12.
        File = 'skills\instrument-observability\SKILL.md'
        Find = @'
RefreshObservabilityToken
'@
        Replace = @'
refreshObservabilityToken
'@
    }
    @{
        # The validator does not check for the per-turn refreshObservabilityToken call that
        # the Node.js OBO token cache depends on. NOTICE.md section 12.
        File = 'hooks\stop\validate-instrument-observability.js'
        Find = @'
    const hasS2SEndpoint = anyFileContains(tsFiles, 'useS2SEndpoint') ||
                           anyFileContains(tsFiles, 'useMicrosoftOpenTelemetry');
    if (!hasS2SEndpoint) {
      issues.push('S2S: useMicrosoftOpenTelemetry() or useS2SEndpoint not found in observability configuration');
    }
  }
'@
        Replace = @'
    const hasS2SEndpoint = anyFileContains(tsFiles, 'useS2SEndpoint') ||
                           anyFileContains(tsFiles, 'useMicrosoftOpenTelemetry');
    if (!hasS2SEndpoint) {
      issues.push('S2S: useMicrosoftOpenTelemetry() or useS2SEndpoint not found in observability configuration');
    }
  }

  // On the OBO path the resolver reads a cache that only refreshObservabilityToken fills,
  // so without the per-turn call nothing is exported. The PascalCase name is undefined
  // and throws on the first turn. See NOTICE.md, section 12.
  if (authMode !== 's2s') {
    const wiresCacheResolver = anyFileContains(tsFiles, 'getObservabilityToken');
    const refreshesPerTurn = anyFileContains(tsFiles, 'refreshObservabilityToken');
    if (wiresCacheResolver && !refreshesPerTurn) {
      issues.push('OBO: tokenResolver reads AgenticTokenCacheInstance but no call to ' +
        'refreshObservabilityToken() was found -- the cache is never filled, the resolver ' +
        'returns "" and no spans are exported. Call it at the start of each handler turn');
    }
    const badCase = tsFiles.filter(f => {
      try {
        return /\.RefreshObservabilityToken\b/.test(fs.readFileSync(f, 'utf8'));
      } catch {
        return false;
      }
    });
    if (badCase.length) {
      issues.push('RefreshObservabilityToken is spelled PascalCase in ' +
        badCase.map(f => path.basename(f)).join(', ') +
        ' -- the shipped API is refreshObservabilityToken (camelCase since GA 1.0); ' +
        'the PascalCase name is undefined and throws on the first turn');
    }
  }
'@
    }
    @{
        # The .NET validator checks that EnableAgent365Exporter exists, not that it is true,
        # and never checks for RegisterObservability. NOTICE.md section 13.
        File = 'hooks\stop\validate-instrument-observability.js'
        Find = @'
  const hasAppSettingsConfig = anyFileContains(appSettingsFiles,
    'EnableAgent365Exporter', 'Agent365Observability');
  if (!hasAppSettingsConfig) {
    issues.push('appsettings.json does not contain A365 observability config (EnableAgent365Exporter)');
  }
'@
        Replace = @'
  const hasAppSettingsConfig = anyFileContains(appSettingsFiles,
    'EnableAgent365Exporter', 'Agent365Observability');
  if (!hasAppSettingsConfig) {
    issues.push('appsettings.json does not contain A365 observability config (EnableAgent365Exporter)');
  }

  // Nothing is exported unless the root appsettings.json enables the exporter.
  // appsettings.Development.json is meant to be false. See NOTICE.md, section 13.
  const hasExporterKey = anyFileContains(appSettingsFiles, 'EnableAgent365Exporter');
  const exporterIsOn = appSettingsFiles.some(f => {
    try {
      return /"EnableAgent365Exporter"\s*:\s*true/i.test(fs.readFileSync(f, 'utf8'));
    } catch {
      return false;
    }
  });
  if (hasExporterKey && !exporterIsOn) {
    issues.push('EnableAgent365Exporter is present in appsettings.json but not "true" -- the agent is instrumented but exports nothing; set it to true and restart');
  }

  // On the OBO path the exporter token comes from a cache that only the per-turn
  // RegisterObservability() call fills. See NOTICE.md, section 13.
  if (authMode !== 's2s' && hasDistroWired && !anyFileContains(csFiles, 'RegisterObservability')) {
    issues.push('OBO: no call to RegisterObservability() found in any .cs file -- the exporter token cache ' +
      'is never filled, so no spans are exported. Call it once per turn in the agent handler');
  }
'@
    }
    @{
        # The run instructions stop making sense once the plugin path is rewritten.
        # NOTICE.md section 7.
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
// Without a plugin install CLAUDE_PLUGIN_ROOT is unset, which would switch this guard
// off. Fall back to the kit folder inside the project. Added by the Agent 365
// Onboarding Kit; see its NOTICE.md, section 3.
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

# The refusal message names an environment variable the user never set.
$guardTextN = Get-Content -LiteralPath $guard -Raw
$guardTextN = $guardTextN.Replace(
    '`Path guard: refusing to write inside CLAUDE_PLUGIN_ROOT (${pluginRoot}). ` +',
    '`Path guard: refusing to write inside the Agent 365 kit folder (${pluginRoot}). ` +')
Set-Content -LiteralPath $guard -Value $guardTextN -NoNewline -Encoding UTF8

# Staged under the kit folder rather than shipped at .github/copilot-instructions.md,
# because that file is often project-owned and an unzip must not overwrite it.
# agent365-kit.ps1 -WireCopilot creates or appends it, so links are relative to .github/.

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

# SDK and playbook corrections, kept as data so each one carries an id and an expected
# match count. Applied after the path-guard patch and the Copilot staging because some
# entries target those outputs.

Step 'Applying upstream correctness fix-ups'

$fixupFile = Join-Path (Join-Path $RepoRoot 'build') 'upstream-fixups.json'
if (Test-Path -LiteralPath $fixupFile) {
    $jsonFixups = Get-Content -LiteralPath $fixupFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $applied = 0
    foreach ($fx in $jsonFixups) {
        $target = Join-Path $KitPath $fx.path
        if (-not (Test-Path -LiteralPath $target)) { throw "Fix-up target missing: $($fx.id) -> $($fx.path)" }
        $content = (Get-Content -LiteralPath $target -Raw) -replace "`r`n", "`n"
        $find    = ($fx.find    -replace "`r`n", "`n")
        $replace = ($fx.replace -replace "`r`n", "`n")
        $count   = ([regex]::Matches($content, [regex]::Escape($find))).Count
        $want    = if ($null -ne $fx.expectedCount) { [int]$fx.expectedCount } else { 1 }
        if ($count -ne $want) {
            throw "Fix-up '$($fx.id)' matched $count time(s) in $($fx.path); expected $want. Upstream changed -- update build/upstream-fixups.json."
        }
        Set-Content -LiteralPath $target -Value $content.Replace($find, $replace) -NoNewline -Encoding UTF8
        $applied++
    }
    Ok "$applied upstream fix-ups applied from upstream-fixups.json"
} else {
    Warn 'build/upstream-fixups.json not found -- no upstream correctness fix-ups applied'
}

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

# The kit redistributes Microsoft's MIT-licensed skills, so both licences and the notice
# ship inside .a365-kit/, not the project root where they would collide with the user's
# own LICENSE. The launchers replace .a365-kit/ whole on update.
function Write-Lf([string] $Path, [string] $Text) {
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}
$upstreamLicense = Join-Path $Upstream 'LICENSE'
if (-not (Test-Path -LiteralPath $upstreamLicense)) { throw 'Upstream LICENSE not found; the kit cannot be redistributed without it.' }
Write-Lf (Join-Path $KitPath 'LICENSE-agent365-skills') ([IO.File]::ReadAllText($upstreamLicense))
Write-Lf (Join-Path $KitPath 'LICENSE') ([IO.File]::ReadAllText((Join-Path $RepoRoot 'LICENSE')))
$repoUrl = 'https://github.com/AkramMSFT/agent365-sdk-onboarding-experience/blob/main/'
$notice = [IO.File]::ReadAllText((Join-Path $RepoRoot 'NOTICE.md'))
$notice = [regex]::Replace($notice, '\]\((?!https?://|#|mailto:)([^)\s]+)\)', { param($m) "]($repoUrl$($m.Groups[1].Value))" })
Write-Lf (Join-Path $KitPath 'NOTICE.md') $notice
Ok 'LICENSE, LICENSE-agent365-skills, NOTICE.md'

# GitHub Copilot reads only .github/copilot-instructions.md, never SKILL.md discovery
# folders, so the add-ons are listed there too. Links are relative to .github/.
function Get-SkillFrontMatter([string] $Path) {
    $lines = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Split("`n")
    if ($lines[0] -ne '---') { throw "No front matter: $Path" }
    $fm = @{}; $key = $null
    for ($i = 1; $i -lt $lines.Count -and $lines[$i] -ne '---'; $i++) {
        $line = $lines[$i]
        if ($line -match '^([A-Za-z_-]+):\s*(.*)$') {
            $key = $Matches[1]; $val = $Matches[2].Trim()
            $fm[$key] = if ($val -in @('>', '|', '>-', '|-')) { '' } else { $val.Trim('"', "'") }
        } elseif ($key -and $line -match '^\s+(\S.*)$') {
            $fm[$key] = ($fm[$key] + ' ' + $Matches[1].Trim()).Trim()
        }
    }
    return $fm
}
$copilotPath = Join-Path $KitPath 'copilot-instructions.md'
$addonRoot = Join-Path $KitPath 'addons'
if ((Test-Path -LiteralPath $copilotPath) -and (Test-Path -LiteralPath $addonRoot)) {
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append("`n---`n`n## Kit add-ons`n`n")
    [void]$sb.Append("These skills ship with the Agent 365 Onboarding Kit, not with Microsoft's skills. When a request matches one of them, follow its SKILL.md exactly.`n")
    foreach ($dir in Get-ChildItem -LiteralPath $addonRoot -Directory | Sort-Object Name) {
        $fm = Get-SkillFrontMatter (Join-Path $dir.FullName 'SKILL.md')
        if ($fm['name'] -ne $dir.Name -or -not $fm['description']) { throw "Add-on front matter incomplete: $($dir.Name)" }
        [void]$sb.Append("`n## Add-on: $($dir.Name)`n`n")
        [void]$sb.Append("**Full instructions:** [$KIT_DIR/addons/$($dir.Name)/SKILL.md](../$KIT_DIR/addons/$($dir.Name)/SKILL.md)`n`n")
        [void]$sb.Append("$($fm['description'])`n")
    }
    $copilotText = [IO.File]::ReadAllText($copilotPath).Replace("`r`n", "`n").TrimEnd() + "`n" + $sb.ToString()
    Write-Lf $copilotPath $copilotText
    Ok 'copilot-instructions.md lists the kit add-ons'
}

$manifest = [ordered]@{
    kitVersion      = $KitVersion
    upstreamRepo    = 'microsoft/agent365-skills'
    upstreamVersion = $UpstreamVersion
    upstreamCommit  = $UpstreamCommit
    builtUtc        = $BuiltUtc
    updateSource    = $UpdateSource
    skills          = @(Get-ChildItem -Path (Join-Path $KitPath 'skills') -Directory | ForEach-Object { $_.Name })
    addons          = @(if (Test-Path -LiteralPath (Join-Path $KitPath 'addons')) {
                          Get-ChildItem -Path (Join-Path $KitPath 'addons') -Directory | ForEach-Object { $_.Name } })
}
$manifest | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $KitPath 'KIT-VERSION.json') -Encoding UTF8
Ok 'KIT-VERSION.json'

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
    # Add-ons live in .a365-kit/addons/, apart from the upstream skills so provenance
    # stays clear, but are discovered the same way.
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

Convert-ToLf -Root $OutDir -What 'payload'

Step 'Verifying build'

$problems = @()

# Only the ${CLAUDE_PLUGIN_ROOT} token is an error, because it resolves to nothing in a
# drop-in install. path-guard.js reads process.env.CLAUDE_PLUGIN_ROOT deliberately, and
# NOTICE.md quotes both forms to document the rewrite.
$noticeCopy = Join-Path $KitPath 'NOTICE.md'
$leftovers = Get-ChildItem -Path $OutDir -Recurse -File -Include '*.md', '*.js', '*.json' |
    Where-Object { $_.FullName -ne $noticeCopy } |
    Select-String -Pattern '${CLAUDE_PLUGIN_ROOT}' -SimpleMatch
if ($leftovers) {
    foreach ($hit in $leftovers) {
        $problems += "leftover `${CLAUDE_PLUGIN_ROOT} token: $($hit.Path):$($hit.LineNumber)"
    }
} else {
    Ok 'no ${CLAUDE_PLUGIN_ROOT} path tokens remain'
}

$nsLeft = Get-ChildItem -Path $OutDir -Recurse -File -Include '*.md', '*.js' |
    Where-Object { $_.FullName -ne $noticeCopy } |
    Select-String -Pattern '/agent365:' -SimpleMatch
if ($nsLeft) {
    foreach ($hit in $nsLeft) { $problems += "leftover /agent365: namespace: $($hit.Path):$($hit.LineNumber)" }
} else {
    Ok 'no /agent365: plugin command references remain'
}

$refPattern = [regex]::Escape($KIT_DIR) + '/[A-Za-z0-9_./-]+'
$checked = 0
$badRefs = @()
$skillMdRoots = @((Join-Path $KitPath 'skills'))
if (Test-Path -LiteralPath (Join-Path $KitPath 'addons')) { $skillMdRoots += (Join-Path $KitPath 'addons') }
foreach ($file in ($skillMdRoots | ForEach-Object { Get-ChildItem -Path $_ -Filter 'SKILL.md' -Recurse })) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($m in [regex]::Matches($text, $refPattern)) {
        $rel = $m.Value.TrimEnd('.', ',', ')', '`')
        # Directory mentions in prose are not checked.
        if ($rel -notmatch '\.(md|js|mjs|json)$') { continue }
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

$jsFiles = @(Get-ChildItem -Path $KitPath -Recurse -File -Include '*.js', '*.mjs')
foreach ($js in $jsFiles) {
    & node --check $js.FullName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $problems += "JS syntax error: $($js.FullName)" }
}
Ok "$($jsFiles.Count) JS/MJS files parse cleanly"

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

$hookCmds = Select-String -Path (Join-Path $KitPath 'skills\*\SKILL.md') -Pattern 'command:\s*node'
foreach ($hit in $hookCmds) {
    if ($hit.Line -notmatch '\$\{CLAUDE_PROJECT_DIR\}') {
        $problems += "hook command not repointed: $($hit.Path):$($hit.LineNumber)"
    }
}
Ok "$($hookCmds.Count) hook commands repointed to `${CLAUDE_PROJECT_DIR}"

# Claims the fix-ups removed must not reappear elsewhere in the shipped guidance.
$retracted = @(
    @{ Pattern = 'auto-registers `IExporterTokenCache'; Why = '.NET token cache is registered explicitly, not by the distro' },
    @{ Pattern = 'Auto-registered by the Microsoft.OpenTelemetry distro'; Why = '.NET token cache is registered explicitly, not by the distro' },
    @{ Pattern = 'cache is auto-registered by `UseMicrosoftOpenTelemetry'; Why = '.NET token cache is registered explicitly, not by the distro' },
    @{ Pattern = 'RefreshObservabilityToken('; Why = 'the Node.js method is refreshObservabilityToken (camelCase)'; CaseSensitive = $true }
)
foreach ($r in $retracted) {
    $hits = Get-ChildItem -Path $KitPath -Recurse -File -Include '*.md' |
        Select-String -Pattern $r.Pattern -SimpleMatch -CaseSensitive:([bool]$r['CaseSensitive'])
    foreach ($hit in $hits) { $problems += "retracted claim '$($r.Pattern)' ($($r.Why)): $($hit.Path):$($hit.LineNumber)" }
}
Ok 'no retracted claims remain in shipped guidance'

foreach ($f in @('LICENSE', 'LICENSE-agent365-skills', 'NOTICE.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $KitPath $f))) { $problems += "missing $KIT_DIR/$f" }
}
if (Test-Path -LiteralPath (Join-Path $KitPath 'addons')) {
    $copilotText = [IO.File]::ReadAllText((Join-Path $KitPath 'copilot-instructions.md'))
    foreach ($a in (Get-ChildItem -LiteralPath (Join-Path $KitPath 'addons') -Directory).Name) {
        if (-not $copilotText.Contains("## Add-on: $a")) { $problems += "copilot-instructions.md does not list add-on $a" }
    }
}
Ok 'licences present; Copilot instructions list every add-on'

if ($problems.Count -gt 0) {
    Write-Host ''
    Fail "$($problems.Count) problem(s):"
    $problems | ForEach-Object { Write-Host "           $_" -ForegroundColor Red }
    throw 'Build verification failed.'
}

if ($Zip) {
    Step 'Packaging'
    $zipName = "agent365-onboarding-kit-v$KitVersion.zip"
    $zipPath = Join-Path $RepoRoot $zipName
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    # -Path with \* keeps the archive rooted at the kit contents, not at kit/.
    Compress-Archive -Path (Join-Path $OutDir '*') -DestinationPath $zipPath -Force
    $sizeKb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB)
    Ok "$zipName ($sizeKb KB)"
}

# tools/prepare-workspace.mjs copies kit/** and examples/<id>/** as listed in
# BUNDLE-MANIFEST.json, verifying each file's SHA-256. Emitted only when the kit was
# built into the repository, because the manifest describes the repository layout.

if ((Resolve-Path -LiteralPath $OutDir).Path.TrimEnd('\') -eq (Join-Path $RepoRoot 'kit')) {
    Step 'Writing BUNDLE-MANIFEST.json and SHA256SUMS.txt'
    $manifestFiles = @()
    $sumLines = @()
    $roots = @('kit', 'examples', 'tools', 'docs', 'README.md', 'GUIDE.md', 'NOTICE.md', 'CONTRIBUTING.md', 'SECURITY.md', 'LICENSE', '.gitattributes')
    # Only files git would publish, tracked or new but never ignored, so a maintainer's
    # .env, a365 config or build output inside examples/ never reaches a release.
    foreach ($root in $roots) {
        $listed = (& git -C $RepoRoot -c core.quotepath=off ls-files --cached --others --exclude-standard -z -- $root) -split "`0"
        if ($LASTEXITCODE -ne 0) { throw "git ls-files failed for $root" }
        foreach ($rel in ($listed | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive)) {
            $abs = Join-Path $RepoRoot $rel
            if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { continue }
            $f = Get-Item -LiteralPath $abs -Force
            $hash = (Get-FileHash -LiteralPath $abs -Algorithm SHA256).Hash.ToLower()
            $manifestFiles += [ordered]@{ path = $rel; bytes = $f.Length; sha256 = $hash }
            $sumLines += "$hash  $rel"
        }
    }
    $examples = @()
    $catalog = Join-Path (Join-Path $RepoRoot 'build') 'bundle-examples.json'
    if (Test-Path -LiteralPath $catalog) { $examples = @(Get-Content -LiteralPath $catalog -Raw -Encoding UTF8 | ConvertFrom-Json) }
    $manifest = [ordered]@{
        schemaVersion   = 1
        bundleVersion   = $KitVersion
        kitVersion      = $KitVersion
        upstreamRepo    = 'microsoft/agent365-skills'
        upstreamVersion = $UpstreamVersion
        upstreamCommit  = $UpstreamCommit
        examples        = $examples
        files           = $manifestFiles
    }
    (($manifest | ConvertTo-Json -Depth 6) -replace "`r`n", "`n") + "`n" | Set-Content -LiteralPath (Join-Path $RepoRoot 'BUNDLE-MANIFEST.json') -NoNewline -Encoding UTF8
    (($sumLines -join "`n") + "`n") | Set-Content -LiteralPath (Join-Path $RepoRoot 'SHA256SUMS.txt') -NoNewline -Encoding UTF8
    Ok "manifest lists $($manifestFiles.Count) files, $($examples.Count) examples"

    if ($Zip) {
        $bundleZip = Join-Path $RepoRoot "agent365-onboarding-bundle-v$KitVersion.zip"
        if (Test-Path -LiteralPath $bundleZip) { Remove-Item -LiteralPath $bundleZip -Force }
        $bundleRel = @($manifestFiles | ForEach-Object { $_.path }) + @('BUNDLE-MANIFEST.json', 'SHA256SUMS.txt')
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::Open($bundleZip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($rel in $bundleRel) {
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $RepoRoot $rel), $rel, [IO.Compression.CompressionLevel]::Optimal)
            }
        } finally { $archive.Dispose() }
        Ok "agent365-onboarding-bundle-v$KitVersion.zip ($([math]::Round((Get-Item -LiteralPath $bundleZip).Length / 1KB)) KB)"
    }
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
