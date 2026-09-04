#!/usr/bin/env node
// Agent 365 Onboarding Kit add-on validator: add-messaging-endpoint.
//
// Checks that a blueprint-based agent has an HTTP host serving /api/messages and
// /api/health, and that the blueprint has a registered HTTPS messaging endpoint.
// Static file checks only -- no network, no build. Exit 0 {"ok":true} / 1 {"ok":false}.

'use strict';

const fs = require('fs');
const path = require('path');
const { scanProject, filterByName } = require('../lib/project-scan');

const cwd = process.cwd();
const issues = [];
const read = p => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
const exists = p => { try { fs.accessSync(p); return true; } catch { return false; } };

// Language from the detection cache, falling back to project files.
let language = '';
try {
  const d = JSON.parse(read(path.join(cwd, '.a365-workspace-detection.local.json')));
  language = String(d.programmingLanguage || '').toLowerCase();
  if (d.agentType && String(d.agentType).toLowerCase() === 'ai-teammate') {
    process.stdout.write(JSON.stringify({ ok: true, note: 'AI Teammate: hosting is owned by make-ai-teammate; add-messaging-endpoint not applicable' }));
    process.exit(0);
  }
} catch { /* no cache */ }
if (!language) {
  if (exists(path.join(cwd, 'pyproject.toml')) || exists(path.join(cwd, 'requirements.txt'))) language = 'python';
  else if (exists(path.join(cwd, 'package.json'))) language = 'nodejs';
  else if (filterByName(scanProject(cwd), '.csproj').length) language = 'dotnet';
}

const all = scanProject(cwd);
const hasBoth = text => text.includes('/api/messages') && text.includes('/api/health');

if (language === 'python') {
  const hosts = filterByName(all, '.py').filter(f => hasBoth(read(f)));
  if (!hosts.length) issues.push('no Python file serves both /api/messages and /api/health -- hosting layer missing');
  else {
    const t = hosts.map(read).join('\n');
    if (t.includes('from_environment()')) issues.push('host uses MsalConnectionManager.from_environment(), which does not exist in microsoft-agents 1.6 -- see python-messaging-endpoint.md');
    if (!t.includes('jwt_authorization_middleware')) issues.push('host does not apply jwt_authorization_middleware -- /api/messages would accept anonymous calls');
    if (!t.includes('start_agent_process')) issues.push('host does not call start_agent_process -- activities will not reach the AgentApplication');
  }
} else if (language === 'nodejs') {
  const hosts = all.filter(f => /\.(ts|js|mjs)$/.test(f) && !f.includes('node_modules')).filter(f => hasBoth(read(f)));
  if (!hosts.length) issues.push('no Node.js file serves both /api/messages and /api/health -- hosting layer missing');
  else if (!hosts.map(read).join('\n').includes('authorizeJWT')) issues.push('host does not apply authorizeJWT -- /api/messages would accept anonymous calls');
} else if (language === 'dotnet') {
  const cs = filterByName(all, '.cs').map(read).join('\n');
  if (!cs.includes('MapAgentApplicationEndpoints') && !cs.includes('/api/messages')) issues.push('no MapAgentApplicationEndpoints() / /api/messages route -- hosting layer missing');
  if (!cs.includes('/api/health')) issues.push('no /api/health endpoint -- add an unauthenticated liveness route');
  if (/MapAgentApplicationEndpoints\([^)]*requireAuth\s*:\s*false/.test(cs)) issues.push('MapAgentApplicationEndpoints(requireAuth: false) -- auth is off; not acceptable for a tunnel or cloud host');
} else {
  issues.push('could not determine the project language (no detection cache, requirements.txt, pyproject.toml, package.json or .csproj)');
}

// Work IQ + Python: the tooling SDK defaults to a DEVELOPMENT environment when none of
// PYTHON_ENVIRONMENT / ENVIRONMENT / ASPNETCORE_ENVIRONMENT / DOTNET_ENVIRONMENT is set,
// which makes it read tokens from BEARER_TOKEN_* env vars instead of doing the OBO
// exchange -- every MCP server then answers 401. Nothing in the CLI or skills sets it.
if (language === 'python' && exists(path.join(cwd, 'ToolingManifest.json'))) {
  const env = read(path.join(cwd, '.env'));
  const envVar = /^\s*(PYTHON_ENVIRONMENT|ENVIRONMENT|ASPNETCORE_ENVIRONMENT|DOTNET_ENVIRONMENT)\s*=\s*(\S+)/im.exec(env);
  if (!envVar) {
    issues.push('WorkIQ is configured but no environment variable is set -- add PYTHON_ENVIRONMENT=Production to .env, or the tooling SDK runs in development mode and every MCP server returns 401');
  } else if (/development/i.test(envVar[2])) {
    issues.push(`${envVar[1]}=${envVar[2]} puts the tooling SDK in development mode; it will read BEARER_TOKEN_* env vars instead of exchanging tokens, and MCP servers will return 401`);
  }
  // Several WorkIQ servers publish colliding tool names (SharePoint and OneDrive both
  // expose getFileOrFolderMetadataByUrl), which raises UserError and fails the turn.
  const serverCount = (() => {
    try {
      const m = JSON.parse(read(path.join(cwd, 'ToolingManifest.json')));
      return (m.mcpServers || m.servers || []).length;
    } catch { return 0; }
  })();
  if (serverCount > 1 && !/include_server_in_tool_names/.test(all.filter(f => f.endsWith('.py')).map(read).join('\n'))) {
    console.warn(`[validate-add-messaging-endpoint] Warning: ${serverCount} WorkIQ servers configured but include_server_in_tool_names is not set -- duplicate tool names across servers will raise UserError at turn time`);
  }
}

// Endpoint registered on the blueprint.
const gen = path.join(cwd, 'a365.generated.config.json');
if (!exists(gen)) issues.push('a365.generated.config.json not found -- run a365-setup first');
else {
  try {
    const g = JSON.parse(read(gen));
    const ep = String(g.messagingEndpoint || '');
    if (!ep) issues.push('messagingEndpoint is empty -- run: a365 setup blueprint --update-endpoint <https-url>/api/messages --m365');
    else {
      if (!ep.startsWith('https://')) issues.push(`messagingEndpoint is not HTTPS: ${ep}`);
      if (!ep.endsWith('/api/messages')) issues.push(`messagingEndpoint does not end in /api/messages: ${ep}`);
    }
    if (g.completed === false) console.warn('[validate-add-messaging-endpoint] Warning: completed=false -- endpoint registration may not have run yet');
  } catch { issues.push('a365.generated.config.json cannot be parsed'); }
}

if (issues.length) { process.stdout.write(JSON.stringify({ ok: false, reason: issues.join('; ') })); process.exit(1); }
process.stdout.write(JSON.stringify({ ok: true }));
process.exit(0);
