#!/usr/bin/env node
// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
/**
 * validate-observability.js
 *
 * Stop hook validator for the instrument-observability skill.
 * Called by the skill's stop hook before the session ends.
 * Checks that observability instrumentation was actually applied.
 *
 * Exit codes:
 *   0  → ok: true  (session may end)
 *   1  → ok: false (session blocked, reason shown to user)
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const {
  scanProject,
  filterByName,
  fileContains,
  anyFileContains,
  readJson,
} = require('../lib/project-scan');

const { selectEnvFiles, envFlagEnabled } = require('../lib/env-config');
const cwd = process.cwd();
const issues = [];

const workspaceDetection = readJson(path.join(cwd, '.a365-workspace-detection.local.json')) || {};
const authMode = (workspaceDetection.authMode || '').toLowerCase();

// ── Detect project type ─────────────────────────────────────────────────────
// Walk the project tree once, then bucket by name.

const allFiles    = scanProject(cwd);
const csprojFiles = filterByName(allFiles, '.csproj');
const tsFiles     = filterByName(allFiles, '.ts', '.js');
const pyFiles     = filterByName(allFiles, '.py');
const envFiles    = selectEnvFiles(filterByName(allFiles, '.env', '.env.example', '.env.production', '.env.local'));
const reqFiles    = filterByName(allFiles, 'requirements.txt', 'pyproject.toml');
const packageJsonFiles = filterByName(allFiles, 'package.json');

const isDotnet   = csprojFiles.length > 0;
// Node.js: any project with a package.json + .ts/.js source files
const isNodejs   = !isDotnet && packageJsonFiles.length > 0 && tsFiles.length > 0;
const isPython   = !isDotnet && !isNodejs && (pyFiles.length > 0 || reqFiles.length > 0);
const isUnknown  = !isDotnet && !isNodejs && !isPython;

if (isUnknown) {
  // No agent project detected — nothing to validate
  process.stdout.write(JSON.stringify({ ok: true }));
  process.exit(0);
}

// ── Detection cache must exist ──────────────────────────────────────────────
// Phase 0.1 triage writes .a365-workspace-detection.local.json via a365-setup.
// Reaching this point means an agent project was detected; the cache must
// exist or the model skipped triage and instrumented against unknown
// authMode / agentStack.

if (!fs.existsSync(path.join(cwd, '.a365-workspace-detection.local.json'))) {
  issues.push('.a365-workspace-detection.local.json was not written — Phase 0 triage was skipped. The skill must run a365-setup (which writes this cache) before any Phase 1 work. Re-run /a365-setup, then re-run /instrument-observability');
}

if (workspaceDetection.observabilityExportMode === 'console') {
  const validateConsoleOnly = require('../lib/console-observability');
  issues.push(...validateConsoleOnly({
    language: isDotnet ? 'dotnet' : isNodejs ? 'node' : 'python',
    files: allFiles, envFiles,
  }));
  process.stdout.write(JSON.stringify(issues.length
    ? { ok: false, reason: issues.join('; ') }
    : { ok: true, note: 'Console-only wiring checked; Agent 365 tokens and backend ingestion were not verified' }));
  process.exit(issues.length ? 1 : 0);
}

// ── .NET validation ─────────────────────────────────────────────────────────

if (isDotnet) {
  // 1. Package installed (Runtime or unified OpenTelemetry distro)
  const hasObservabilityPkg = csprojFiles.some(f =>
    fileContains(f, 'Microsoft.Agents.A365.Observability.Runtime') ||
    fileContains(f, 'Microsoft.OpenTelemetry'));
  if (!hasObservabilityPkg) {
    issues.push('Microsoft.Agents.A365.Observability.Runtime or Microsoft.OpenTelemetry package is not referenced in any .csproj');
  }

  // 2. Program.cs wired
  // Preferred (Microsoft.OpenTelemetry distro): UseMicrosoftOpenTelemetry covers both OBO and S2S
  //   - OBO/agentic-user: explicitly register/connect the cache, or supply a custom TokenResolver
  //   - S2S: UseMicrosoftOpenTelemetry + AddAgent365Observability for the scaffold token service
  // Legacy (pre-distro, kept for older agents): AddA365Tracing + AddAgenticTracingExporter (OBO)
  //   or AddA365Tracing + AddAgent365Observability (S2S)
  const programFiles = filterByName(allFiles, '.cs').filter(f => !/(?:^|[\\/])tests?[\\/]|(?:Tests|Checks)\.cs$/i.test(f));
  const hasDistroWired = anyFileContains(programFiles, 'UseMicrosoftOpenTelemetry');
  const hasLegacyOBOWired = anyFileContains(programFiles, 'AddA365Tracing', 'AddAgenticTracingExporter');
  const hasLegacyS2SWired = anyFileContains(programFiles, 'AddA365Tracing', 'AddAgent365Observability') ||
                            anyFileContains(programFiles, 'UseMicrosoftOpenTelemetry', 'AddAgent365Observability');
  const hasProgramWired = hasDistroWired || hasLegacyOBOWired || hasLegacyS2SWired;
  if (!hasProgramWired) {
    issues.push('Program.cs does not wire A365 observability: expected builder.UseMicrosoftOpenTelemetry(o => ...) (preferred — Microsoft.OpenTelemetry distro) or the legacy AddA365Tracing(...) + AddAgenticTracingExporter(...) (OBO) / AddAgent365Observability() (S2S) calls');
  }

  // 2a. Legacy OBO only: WithAgentFramework() must be configured in AddA365Tracing.
  // The distro auto-instruments AgentFramework via o.Instrumentation.EnableAgentFrameworkInstrumentation
  // (default true), so this check does NOT apply when UseMicrosoftOpenTelemetry is used.
  if (hasLegacyOBOWired && !hasDistroWired && authMode !== 's2s') {
    const hasWithAgentFramework = anyFileContains(programFiles, 'WithAgentFramework');
    if (!hasWithAgentFramework) {
      issues.push('Program.cs calls AddA365Tracing() but WithAgentFramework() is missing — use AddA365Tracing(config => { config.WithAgentFramework(); }) for correct OBO tracing (legacy path; prefer migrating to UseMicrosoftOpenTelemetry from the Microsoft.OpenTelemetry distro)');
    }
    // 2b. clusterCategory: "production" must be present in AddAgenticTracingExporter (legacy only)
    const hasClusterCategory = anyFileContains(programFiles, 'clusterCategory');
    if (!hasClusterCategory) {
      issues.push('AddAgenticTracingExporter() is missing the required clusterCategory: "production" argument — use AddAgenticTracingExporter(clusterCategory: "production") (legacy path; prefer migrating to UseMicrosoftOpenTelemetry)');
    }
  }

  // 3. Observability context wired in agent code
  // OBO path: BaggageBuilder or BaggageTurnMiddleware
  // S2S path: ObservabilityTokenService scaffold + Agent365ObservabilityContext injection
  const csFiles = filterByName(allFiles, '.cs');
  const hasS2SScaffold = anyFileContains(csFiles, 'ObservabilityTokenService') ||
                         anyFileContains(csFiles, 'Agent365ObservabilityContext');
  const hasBaggage = anyFileContains(csFiles, 'BaggageBuilder') ||
                     anyFileContains([...programFiles, ...csFiles], 'BaggageTurnMiddleware') ||
                     hasS2SScaffold;
  if (!hasBaggage) {
    issues.push('No .cs file uses BaggageBuilder, BaggageTurnMiddleware (OBO), or ObservabilityTokenService/Agent365ObservabilityContext (S2S) — observability context is missing');
  }

  // 3a. Manual instrumentation scope wired — required for store publishing.
  // Only enforced on the modern Microsoft.OpenTelemetry distro path. Legacy
  // AddA365Tracing / AddAgenticTracingExporter wiring predates the scope API
  // and is not gated on it here to avoid breaking older agents — they cannot
  // pass store publishing without migrating to the distro anyway.
  if (hasDistroWired) {
    const hasScope = anyFileContains(csFiles, 'InvokeAgentScope') ||
                     anyFileContains(csFiles, 'InferenceScope') ||
                     anyFileContains(csFiles, 'ExecuteToolScope');
    if (!hasScope) {
      issues.push('No .cs file uses InvokeAgentScope.Start, InferenceScope.Start, or ExecuteToolScope.Start — manual instrumentation scopes are required for Agent 365 store publishing under the Microsoft.OpenTelemetry distro');
    }
  }

  // 4. appsettings has observability config
  const appSettingsFiles = allFiles.filter(f => /(?:^|[\\/])(?:appsettings(?:\.[^\\/]+)?\.json|\.a365-runtime\.local\.json)$/.test(f));
  const hasAppSettingsConfig = anyFileContains(appSettingsFiles,
    'EnableAgent365Exporter', 'Agent365Observability');
  if (!hasAppSettingsConfig) {
    issues.push('appsettings.json does not contain A365 observability config (EnableAgent365Exporter)');
  }

  // The unified distro selection overrides the legacy root flag.
  const explicitTargets = hasDistroWired ? csFiles.flatMap(f => {
    try {
      return [...fs.readFileSync(f, 'utf8').matchAll(/\bExporters\s*=\s*((?:ExportTarget\.\w+\s*(?:\|\s*)?)+);/g)]
        .map(match => match[1]);
    } catch { return []; }
  }) : [];
  const explicitAgent365 = explicitTargets.some(target => /\bExportTarget\.Agent365\b/.test(target));
  const hasExporterKey = anyFileContains(appSettingsFiles, 'EnableAgent365Exporter');
  // Only the root appsettings.json decides the legacy flag. appsettings.Development.json is
  // meant to be false. Variants are still scanned for the key's presence above.
  const rootAppSettings = appSettingsFiles.filter(f => /(?:^|[\\/])appsettings\.json$/.test(f));
  const exporterIsOn = rootAppSettings.some(f => {
    try {
      return /"EnableAgent365Exporter"\s*:\s*true/i.test(fs.readFileSync(f, 'utf8'));
    } catch {
      return false;
    }
  });
  if (explicitTargets.length && !explicitAgent365) {
    issues.push('The explicit unified-distro exporter selection excludes Agent365; select Agent365 for backend telemetry or record an intentional console-only mode');
  } else if (hasExporterKey && !exporterIsOn && !explicitAgent365) {
    issues.push('No enabled Agent365 exporter found in the root flag or an explicit unified-distro selection; verify the effective exporter configuration');
  }

  // The distro needs an explicit OBO resolver. Custom resolvers need not use the SDK cache.
  if (authMode !== 's2s' && hasDistroWired && !anyFileContains(csFiles, 'TokenResolver')) {
    issues.push('OBO: wire Agent365.TokenResolver explicitly; UseMicrosoftOpenTelemetry does not automatically register and connect the application token cache');
  }
  const usesSdkTokenCache = anyFileContains(csFiles, 'IExporterTokenCache') ||
    anyFileContains(csFiles, 'AgenticTokenCache');
  if (authMode !== 's2s' && hasDistroWired && usesSdkTokenCache && !anyFileContains(csFiles, 'RegisterObservability')) {
    issues.push('OBO: no call to RegisterObservability() found in any .cs file -- the exporter token cache ' +
      'is never filled, so no spans are exported. Call it once per turn in the agent handler');
  }

  // 5. Logging config present — required for logs to appear in Microsoft Defender
  const hasLoggingConfig = appSettingsFiles.some(f =>
    fileContains(f, 'Microsoft.Agents.A365.Observability') && fileContains(f, 'OpenTelemetry'));
  if (!hasLoggingConfig) {
    console.warn('[validate-instrument-observability] Logging categories are not explicitly configured in JSON; verify operational diagnostics separately. This is not proof that backend telemetry is absent.');
  }
}

// ── Node.js validation ──────────────────────────────────────────────────────

if (isNodejs) {
  // 1. Core package installed — @microsoft/opentelemetry (GA 1.0+) is the unified package.
  // Legacy @microsoft/agents-a365-observability* packages are deprecated but still accepted
  // here so agents instrumented before the rewrite pass validation until they migrate.
  const hasNpmPkg = packageJsonFiles.some(f =>
    fileContains(f, '@microsoft/opentelemetry') ||
    fileContains(f, '@microsoft/agents-a365-observability'));
  if (!hasNpmPkg) {
    issues.push('@microsoft/opentelemetry is not in package.json');
  }

  // 2. useMicrosoftOpenTelemetry called (or legacy ObservabilityManager.configure)
  const hasObsManager = anyFileContains(tsFiles, 'useMicrosoftOpenTelemetry') ||
                        anyFileContains(tsFiles, 'ObservabilityManager');
  if (!hasObsManager) {
    issues.push('No TypeScript/JS file calls useMicrosoftOpenTelemetry()');
  }

  // 3. Baggage wiring — in 1.0+ the recommended pattern is configureA365Hosting({ enableBaggage: true }).
  // Legacy patterns (BaggageBuilder, BaggageMiddleware, BaggageBuilderUtils) still accepted.
  const hasBaggage = anyFileContains(tsFiles, 'configureA365Hosting') ||
                     anyFileContains(tsFiles, 'BaggageMiddleware') ||
                     anyFileContains(tsFiles, 'BaggageBuilder') ||
                     anyFileContains(tsFiles, 'BaggageBuilderUtils');
  if (!hasBaggage) {
    issues.push('No TypeScript/JS file uses configureA365Hosting, BaggageMiddleware, BaggageBuilder, or BaggageBuilderUtils — baggage context missing');
  }

  // 3a. Manual instrumentation scope wired — required for store publishing.
  // Per nodejs-observability.md: InvokeAgentScope, InferenceScope, and ExecuteToolScope are
  // the store-publish-validation gate. The Claude SDK pattern uses only InferenceScope (per-call
  // wrap inside src/client.ts), so accept ANY of the three as sufficient evidence of scope wiring.
  // Only enforced on the modern @microsoft/opentelemetry distro path — legacy
  // ObservabilityManager.configure wiring predates the scope API.
  const usesDistro = anyFileContains(tsFiles, 'useMicrosoftOpenTelemetry');
  if (usesDistro) {
    const hasScope = anyFileContains(tsFiles, 'InvokeAgentScope') ||
                     anyFileContains(tsFiles, 'InferenceScope') ||
                     anyFileContains(tsFiles, 'ExecuteToolScope');
    if (!hasScope) {
      issues.push('No TypeScript/JS file uses InvokeAgentScope.start, InferenceScope.start, or ExecuteToolScope.start — manual instrumentation scopes are required for Agent 365 store publishing under the @microsoft/opentelemetry distro');
    }
  }

  // 4. Token caching wired (tokenResolver, AgenticTokenCacheInstance, preloadObservabilityToken helper, or S2S token service)
  const hasTokenCache = anyFileContains(tsFiles, 'tokenResolver') ||
                        anyFileContains(tsFiles, 'AgenticTokenCacheInstance') ||
                        anyFileContains(tsFiles, 'RefreshObservabilityToken') ||
                        anyFileContains(tsFiles, 'preloadObservabilityToken') ||
                        anyFileContains(tsFiles, 'getS2SObservabilityToken');
  if (!hasTokenCache) {
    issues.push('No TypeScript/JS file wires a token resolver — observability exports will fail');
  }

  // 4a. S2S scaffold: token service file must exist when authMode is s2s
  if (authMode === 's2s') {
    const hasS2SScaffold = anyFileContains(tsFiles, 'observability-token-service') ||
                           anyFileContains(tsFiles, 'startObservabilityTokenService') ||
                           anyFileContains(tsFiles, 'startTokenService');
    if (!hasS2SScaffold) {
      issues.push('S2S: observability/observability-token-service.ts scaffold or startTokenService() not found');
    }
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

  // 5. .env has observability vars
  const codeExporterFlags = tsFiles.flatMap(f => {
    try {
      return [...fs.readFileSync(f, 'utf8').matchAll(/\benableObservabilityExporter\s*:\s*(true|false)\b/g)]
        .map(match => match[1]);
    } catch { return []; }
  });
  const exporterEnabled = codeExporterFlags.includes('true') ||
    (!codeExporterFlags.includes('false') && envFlagEnabled(envFiles, 'ENABLE_A365_OBSERVABILITY_EXPORTER'));
  if (!exporterEnabled) {
    issues.push('No enabled Agent 365 exporter found: check enableObservabilityExporter in code and ENABLE_A365_OBSERVABILITY_EXPORTER in the selected environment configuration; explicit Node options override the environment');
  }
}

// ── Python validation ───────────────────────────────────────────────────────

if (isPython) {
  // 1. Core package installed — microsoft-opentelemetry (GA 1.1+) is the unified package.
  // Legacy microsoft-agents-a365-* packages are deprecated but still accepted here so
  // agents instrumented before the rewrite pass validation until they migrate.
  const pyObservabilityPackages = [
    'microsoft-opentelemetry',
    'microsoft-agents-a365-observability-core',
    'microsoft-agents-a365-observability-hosting',
    'microsoft-agents-a365-observability-runtime',
    'microsoft-agents-a365-observability',
  ];
  const hasPyPkg = reqFiles.some(f =>
    pyObservabilityPackages.some(pkg => fileContains(f, pkg)));
  if (!hasPyPkg) {
    issues.push(
      'microsoft-opentelemetry not found in requirements.txt or pyproject.toml'
    );
  }

  // 2. use_microsoft_opentelemetry() called (or legacy configure())
  const hasConfigure = anyFileContains(pyFiles, 'use_microsoft_opentelemetry') ||
                       (anyFileContains(pyFiles, 'from microsoft_agents_a365.observability.core import') &&
                        anyFileContains(pyFiles, 'configure('));
  if (!hasConfigure) {
    issues.push('No Python file calls use_microsoft_opentelemetry()');
  }

  // 3. BaggageBuilder or BaggageMiddleware used (OBO path) OR use_microsoft_opentelemetry (S2S distro handles context internally)
  const hasBaggage = anyFileContains(pyFiles, 'BaggageBuilder') ||
                     anyFileContains(pyFiles, 'BaggageMiddleware') ||
                     anyFileContains(pyFiles, 'populate_baggage') ||
                     anyFileContains(pyFiles, 'use_microsoft_opentelemetry');
  if (!hasBaggage) {
    issues.push('No Python file uses BaggageBuilder, BaggageMiddleware, populate_baggage, or use_microsoft_opentelemetry — baggage context missing');
  }

  // 3a. Manual instrumentation scope wired — required for store publishing.
  // Same rationale as Node.js: store-validation requires at least one of InvokeAgentScope,
  // InferenceScope, or ExecuteToolScope to be present in agent code. Only enforced on the
  // modern microsoft-opentelemetry distro path; legacy configure() wiring predates scopes.
  const usesDistroPy = anyFileContains(pyFiles, 'use_microsoft_opentelemetry');
  if (usesDistroPy) {
    const hasScope = anyFileContains(pyFiles, 'InvokeAgentScope') ||
                     anyFileContains(pyFiles, 'InferenceScope') ||
                     anyFileContains(pyFiles, 'ExecuteToolScope');
    if (!hasScope) {
      issues.push('No Python file uses InvokeAgentScope, InferenceScope, or ExecuteToolScope — manual instrumentation scopes are required for Agent 365 store publishing under the microsoft-opentelemetry distro');
    }
  }

  // 4. Token cache wired
  // OBO path: cache_agentic_token (new pattern) or AgenticTokenCache (legacy) or exchange_token helper
  // S2S path: get_s2s_observability_token or token_resolver
  // Distro path: use_microsoft_opentelemetry handles it internally
  const hasTokenCache = anyFileContains(pyFiles, 'cache_agentic_token') ||
                        anyFileContains(pyFiles, 'exchange_token') ||
                        anyFileContains(pyFiles, 'AgenticTokenCache') ||
                        anyFileContains(pyFiles, 'token_resolver') ||
                        anyFileContains(pyFiles, 'get_observability_authentication_scope') ||
                        anyFileContains(pyFiles, 'get_s2s_observability_token') ||
                        anyFileContains(pyFiles, 'use_microsoft_opentelemetry');
  if (!hasTokenCache) {
    issues.push('No Python file wires a token resolver — observability exports will fail');
  }

  // 4a. S2S scaffold: token service file must exist when authMode is s2s
  if (authMode === 's2s') {
    const hasS2SScaffold = anyFileContains(pyFiles, 'observability_token_service') ||
                           anyFileContains(pyFiles, 'start_observability_token_service') ||
                           anyFileContains(pyFiles, 'run_token_service');
    if (!hasS2SScaffold) {
      issues.push('S2S: observability/observability_token_service.py scaffold or run_token_service() not found');
    }
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

  // 5. .env has observability vars
  const codeExporterEnabled = pyFiles.some(f => {
    try {
      return /\ba365_enable_observability_exporter\s*=\s*True\b/.test(fs.readFileSync(f, 'utf8'));
    } catch { return false; }
  });
  if (!codeExporterEnabled && !envFlagEnabled(envFiles, 'ENABLE_A365_OBSERVABILITY_EXPORTER')) {
    issues.push('No enabled Agent 365 exporter found: set a365_enable_observability_exporter=True in code or ENABLE_A365_OBSERVABILITY_EXPORTER=true in the selected environment configuration');
  }
}

// ── Build check ─────────────────────────────────────────────────────────────

function runBuild(cmd, timeoutMs) {
  try {
    const out = execSync(cmd, { cwd, timeout: timeoutMs, stdio: 'pipe' }).toString();
    return { ok: true, output: out };
  } catch (e) {
    const out = [(e.stdout || '').toString(), (e.stderr || '').toString()].join('\n').trim();
    return { ok: false, output: out.slice(0, 400) };
  }
}

if (!process.env.VALIDATE_SKIP_EXEC) {
  if (isDotnet) {
    const result = runBuild('dotnet build --no-restore -v minimal', 25000);
    if (!result.ok || !result.output.includes('Build succeeded')) {
      issues.push('dotnet build --no-restore failed — fix compilation errors before ending the session');
    }
  } else if (isNodejs) {
    const result = runBuild('npx tsc --noEmit', 15000);
    if (!result.ok) {
      issues.push('TypeScript compilation failed (tsc --noEmit) — fix errors before ending the session');
    }
  }
}
// Python has no compilation step — import checks are covered by the pattern checks above.

// ── Result ──────────────────────────────────────────────────────────────────

if (issues.length > 0) {
  process.stdout.write(JSON.stringify({
    ok: false,
    reason: issues.join('; ')
  }));
  process.exit(1);
} else {
  process.stdout.write(JSON.stringify({ ok: true }));
  process.exit(0);
}
