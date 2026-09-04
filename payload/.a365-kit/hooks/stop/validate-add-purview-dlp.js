#!/usr/bin/env node
// Agent 365 Onboarding Kit add-on validator: add-purview-dlp.
//
// Checks that Purview runtime DLP is wired: a DLP module calling both Graph endpoints,
// both activities (uploadText + downloadText) referenced from the turn path, the
// token-subject rule applied, and configuration present. Static checks only.

'use strict';

const fs = require('fs');
const path = require('path');
const { scanProject, filterByName } = require('../lib/project-scan');

const cwd = process.cwd();
const issues = [];
const read = p => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
const exists = p => { try { fs.accessSync(p); return true; } catch { return false; } };

const all = scanProject(cwd);
const code = all.filter(f => /\.(py|ts|js|mjs|cs)$/.test(f) && !f.includes('node_modules'));
const text = code.map(read).join('\n');

// 1. The DLP module: both Graph endpoints present somewhere in code.
if (!text.includes('protectionScopes/compute')) issues.push('no code calls dataSecurityAndGovernance/protectionScopes/compute -- DLP module missing');
if (!text.includes('processContent')) issues.push('no code calls dataSecurityAndGovernance/processContent -- DLP module missing');

// 2. Both activities are evaluated on the turn path.
if (!text.includes('uploadText')) issues.push('uploadText (prompt) is never evaluated');
if (!text.includes('downloadText')) issues.push('downloadText (response) is never evaluated');

// 3. The token-subject rule: users/{id} must be the oid of the exchanged token.
if (!/token_object_id|tokenObjectId|TokenObjectId/.test(text)) {
  issues.push('no token-subject helper (token_object_id / tokenObjectId / TokenObjectId) -- addressing the caller instead of the token oid yields Graph 400');
}

// 4. Both scopes requested in the exchange.
if (!text.includes('Content.Process.User')) issues.push('Content.Process.User scope not requested in the token exchange');
if (!text.includes('ProtectionScopes.Compute.User')) issues.push('ProtectionScopes.Compute.User scope not requested in the token exchange');

// 5. Configuration.
const envPath = path.join(cwd, '.env');
const appsettings = filterByName(all, 'appsettings.json').map(read).join('\n');
const cfg = (exists(envPath) ? read(envPath) : '') + '\n' + appsettings;
const cfgHas = k => new RegExp(`(^|\\n|")\\s*${k}\\s*[=:]`, 'm').test(cfg);
if (!cfgHas('ENABLE_PURVIEW_DLP')) issues.push('ENABLE_PURVIEW_DLP not set in .env / appsettings.json');
if (!cfgHas('PURVIEW_APP_LOCATION_ID')) issues.push('PURVIEW_APP_LOCATION_ID not set -- this is the agent identity appId that Purview policies target');
else {
  const m = cfg.match(/PURVIEW_APP_LOCATION_ID\s*[=:]\s*"?([0-9a-fA-F-]{36})/);
  if (!m) console.warn('[validate-add-purview-dlp] Warning: PURVIEW_APP_LOCATION_ID does not look like a GUID');
}

if (issues.length) { process.stdout.write(JSON.stringify({ ok: false, reason: issues.join('; ') })); process.exit(1); }
process.stdout.write(JSON.stringify({ ok: true }));
process.exit(0);
