#!/usr/bin/env node
// Agent 365 Onboarding Kit add-on validator: add-lab-tools.
//
// Confirms the lab-tools module exists, is wired into the agent's tool list without
// replacing the existing tools, and -- when the web group is present -- that fetch_url
// carries its guards. Static checks only; exit 0 {"ok":true} / 1 {"ok":false}.

'use strict';

const fs = require('fs');
const path = require('path');
const { scanProject, filterByName } = require('../lib/project-scan');

const cwd = process.cwd();
const issues = [];
const read = p => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
const exists = p => { try { fs.accessSync(p); return true; } catch { return false; } };

let language = '';
try {
  language = String(JSON.parse(read(path.join(cwd, '.a365-workspace-detection.local.json'))).programmingLanguage || '').toLowerCase();
} catch { /* fall through */ }
if (!language) {
  if (exists(path.join(cwd, 'pyproject.toml')) || exists(path.join(cwd, 'requirements.txt'))) language = 'python';
  else if (exists(path.join(cwd, 'package.json'))) language = 'nodejs';
  else if (filterByName(scanProject(cwd), '.csproj').length) language = 'dotnet';
}

const all = scanProject(cwd);
const modulePattern = { python: /lab_tools\.py$/, nodejs: /lab[_-]?[Tt]ools\.(ts|js|mjs)$/, dotnet: /LabTools\.cs$/ }[language];
const moduleFiles = modulePattern ? all.filter(f => modulePattern.test(f)) : [];

if (!moduleFiles.length) {
  issues.push('no lab-tools module found (expected lab_tools.py / labTools.ts / LabTools.cs) -- add-lab-tools did not create it');
} else {
  const modText = moduleFiles.map(read).join('\n');
  // At least one recognised tool must be defined.
  const known = ['fetch_url', 'fetchUrl', 'FetchUrl', 'encode_text', 'encodeText', 'EncodeText',
                 'hash_text', 'hashText', 'HashText', 'transform_text', 'transformText'];
  if (!known.some(n => modText.includes(n))) {
    issues.push('lab-tools module exists but defines none of the expected tools');
  }
  // If the web group is present, fetch_url must be capped, not an unbounded GET.
  const hasWeb = /fetch_url|fetchUrl|FetchUrl/.test(modText);
  if (hasWeb) {
    const guarded = /timeout|Timeout|TIMEOUT/.test(modText)
      && /https?:\/\/|startswith\(.http|StartsWith\("http|\^https\?/.test(modText)
      && /MAX_FETCH|MaxFetch|slice\(|\[:_?MAX|\[\.\.MaxFetch/.test(modText);
    if (!guarded) {
      issues.push('fetch_url is present but missing one of its guards (http/https-only, timeout, size cap) -- see the reference');
    }
  }
}

// Wired into the agent, and the existing tools preserved.
const agentFiles = {
  python: filterByName(all, '.py').filter(f => /tools\s*=\s*\[/.test(read(f))),
  nodejs: all.filter(f => /\.(ts|js|mjs)$/.test(f) && /tools\s*:\s*\[/.test(read(f)) && !f.includes('node_modules')),
  dotnet: filterByName(all, '.cs').filter(f => /AIFunctionFactory|Tools\s*=|AddAgent/.test(read(f))),
}[language] || [];

const agentText = agentFiles.map(read).join('\n');
if (!/LAB_TOOLS|labTools|LabTools/.test(agentText)) {
  issues.push('the lab tools are not imported into the agent -- append them to the agent tools list (do not replace the existing tools)');
} else if (language === 'python' && /tools\s*=\s*\[[^\]]*\]/.test(agentText)) {
  // Guard against a wholesale replacement: the built-in tools should still be listed.
  const m = agentText.match(/tools\s*=\s*\[([^\]]*)\]/);
  if (m && /LAB_TOOLS/.test(m[1]) && !/get_policy|look_up|_report/.test(m[1]) && !/\*/.test(m[1])) {
    console.warn('[validate-add-lab-tools] Warning: the tools list references LAB_TOOLS but not the original tools -- confirm they were appended, not replaced');
  }
}

if (issues.length) { process.stdout.write(JSON.stringify({ ok: false, reason: issues.join('; ') })); process.exit(1); }
process.stdout.write(JSON.stringify({ ok: true }));
process.exit(0);
