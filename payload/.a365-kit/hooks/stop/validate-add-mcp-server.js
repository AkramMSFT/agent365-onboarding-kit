#!/usr/bin/env node
// Agent 365 Onboarding Kit add-on validator: add-mcp-server.
//
// Confirms an external-MCP wiring module exists, uses the SDK's MCP classes, is attached
// to the agent's mcp_servers without disturbing Work IQ, and does not hard-code secrets.
// Static checks only; exit 0 {"ok":true} / 1 {"ok":false}.

'use strict';

const fs = require('fs');
const path = require('path');
const { scanProject, filterByName } = require('../lib/project-scan');

const cwd = process.cwd();
const issues = [];
const readFile = p => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
const exists = p => { try { fs.accessSync(p); return true; } catch { return false; } };

let language = '';
try {
  language = String(JSON.parse(readFile(path.join(cwd, '.a365-workspace-detection.local.json'))).programmingLanguage || '').toLowerCase();
} catch { /* fall through */ }
if (!language) {
  if (exists(path.join(cwd, 'pyproject.toml')) || exists(path.join(cwd, 'requirements.txt'))) language = 'python';
  else if (exists(path.join(cwd, 'package.json'))) language = 'nodejs';
  else if (filterByName(scanProject(cwd), '.csproj').length) language = 'dotnet';
}

const all = scanProject(cwd);
const modPattern = { python: /mcp_servers\.py$/, nodejs: /mcp[Ss]ervers\.(ts|js|mjs)$/, dotnet: /ExternalMcpServers\.cs$/ }[language];
const modFiles = modPattern ? all.filter(f => modPattern.test(f)) : [];

if (!modFiles.length) {
  issues.push('no external-MCP module found (expected mcp_servers.py / mcpServers.ts / ExternalMcpServers.cs) -- add-mcp-server did not create it');
} else {
  const modText = modFiles.map(readFile).join('\n');
  // Uses a real MCP client class.
  if (!/MCPServerStdio|MCPServerStreamableHttp|MCPServerSse|McpClientFactory|StdioClientTransport/.test(modText)) {
    issues.push('external-MCP module does not reference an SDK MCP class (MCPServerStdio / MCPServerStreamableHttp / McpClientFactory)');
  }
  // No hard-coded secrets: a token-shaped literal assigned inline is a finding.
  if (/(token|secret|password|connectionstring|conn_str)\s*[:=]\s*["'][A-Za-z0-9._~+/\-]{16,}/i.test(modText)
      && !/getenv|process\.env|Environment\.GetEnvironmentVariable/i.test(modText)) {
    issues.push('a credential looks hard-coded in the external-MCP module -- read it from the environment instead');
  }
}

// Attached to the agent, Work IQ preserved.
const agentFiles = {
  python: filterByName(all, '.py').filter(f => /mcp_servers\s*=/.test(readFile(f))),
  nodejs: all.filter(f => /\.(ts|js|mjs)$/.test(f) && /mcpServers\s*:/.test(readFile(f)) && !f.includes('node_modules')),
  dotnet: filterByName(all, '.cs').filter(f => /ExternalMcpServers|ListToolsAsync|AddAgent/.test(readFile(f))),
}[language] || [];
const agentText = agentFiles.map(readFile).join('\n');

if (!/EXTERNAL_MCP_SERVERS|buildExternalMcpServers|ExternalMcpServers|externalMcp/.test(agentText)) {
  issues.push('the external MCP servers are not attached to the agent -- append them to mcp_servers (do not replace the Work IQ servers)');
}

// If Work IQ is also present, names must be namespaced or external + Work IQ tools can collide.
if (language === 'python' && /add_tool_servers_to_agent|setup_workiq_tools/.test(all.filter(f => f.endsWith('.py')).map(readFile).join('\n'))
    && !/include_server_in_tool_names/.test(agentText + all.filter(f => f.endsWith('.py')).map(readFile).join('\n'))) {
  console.warn('[validate-add-mcp-server] Warning: Work IQ and external MCP are both present but include_server_in_tool_names is not set -- tool names can collide across servers');
}

if (issues.length) { process.stdout.write(JSON.stringify({ ok: false, reason: issues.join('; ') })); process.exit(1); }
process.stdout.write(JSON.stringify({ ok: true }));
process.exit(0);
