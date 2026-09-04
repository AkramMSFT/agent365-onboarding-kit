#!/usr/bin/env node
// Agent 365 Onboarding Kit -- prerequisite doctor.
//
// Cross-platform prereq check shared by Start-Agent365-Onboarding.ps1 (Windows)
// and start-agent365-onboarding.sh (macOS/Linux). Reports what is present, what
// is missing, and the exact command to install each missing piece.
//
// Exit codes:
//   0 -> all REQUIRED prerequisites present (optional ones may be missing)
//   1 -> at least one REQUIRED prerequisite missing
//
// Flags:
//   --json   emit a machine-readable report instead of the human table
//   --quiet  suppress the "all good" rows, print only problems

'use strict';

const { execSync } = require('child_process');

const args = new Set(process.argv.slice(2));
const asJson = args.has('--json');
const quiet = args.has('--quiet');

const isWin = process.platform === 'win32';

function probe(cmd) {
  try {
    return execSync(cmd, {
      encoding: 'utf8',
      timeout: 20000,
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
  } catch {
    return null;
  }
}

// Extract the first dotted version number from arbitrary CLI output.
function firstVersion(text) {
  if (!text) return null;
  const m = text.match(/\d+\.\d+(\.\d+)?/);
  return m ? m[0] : null;
}

function majorOf(version) {
  if (!version) return -1;
  return parseInt(version.split('.')[0], 10);
}

// -- The prerequisite matrix -------------------------------------------------
// required: true  -> onboarding cannot start without it.
// required: false -> needed only for specific agent stacks or later phases.

const CHECKS = [
  {
    key: 'node',
    label: 'Node.js 18+',
    required: true,
    why: 'Runs the skill validators bundled with this kit.',
    probe: () => process.version.replace(/^v/, ''),
    ok: v => majorOf(v) >= 18,
    install: isWin
      ? 'winget install --id OpenJS.NodeJS.LTS -e'
      : 'brew install node   # or https://nodejs.org',
  },
  {
    key: 'ai_cli',
    label: 'An AI coding CLI',
    required: true,
    why: 'Reads the skills and drives the onboarding. Any one of these is enough.',
    // Passes if at least one supported CLI is on PATH; reports which.
    probe: () => {
      const found = [];
      if (probe('claude --version')) found.push('Claude Code');
      if (probe(isWin ? 'where copilot' : 'command -v copilot')) found.push('Copilot CLI');
      if (probe(isWin ? 'where cursor-agent' : 'command -v cursor-agent')) found.push('Cursor');
      if (probe(isWin ? 'where gemini' : 'command -v gemini')) found.push('Gemini CLI');
      return found.length ? found.join(', ') : null;
    },
    ok: v => !!v,
    install: 'pick one -- Copilot: npm install -g @github/copilot   |   '
      + 'Claude Code: npm install -g @anthropic-ai/claude-code   |   '
      + 'Cursor / Codex / Gemini CLI: install per their docs',
  },
  {
    key: 'dotnet',
    label: '.NET SDK 8+',
    required: true,
    why: 'The a365 CLI ships as a .NET global tool. SDK, not just runtime.',
    probe: () => firstVersion(probe('dotnet --version')),
    ok: v => majorOf(v) >= 8,
    install: isWin
      ? 'winget install --id Microsoft.DotNet.SDK.8 -e'
      : 'brew install --cask dotnet-sdk   # or https://dot.net/download',
  },
  {
    key: 'a365',
    label: 'a365 CLI',
    required: true,
    why: 'Creates the Agent 365 Blueprint and Entra identity for your agent.',
    probe: () => firstVersion(probe('a365 --version')),
    ok: v => !!v,
    install: 'dotnet tool install -g Microsoft.Agents.A365.DevTools.Cli',
  },
  {
    key: 'az',
    label: 'Azure CLI',
    required: true,
    why: 'Tenant sign-in and Entra app registration.',
    probe: () => firstVersion(probe('az version')),
    ok: v => !!v,
    install: isWin
      ? 'winget install --id Microsoft.AzureCLI -e'
      : 'brew install azure-cli',
  },
  {
    key: 'azlogin',
    label: 'Azure CLI signed in',
    required: false,
    why: 'Setup needs an authenticated tenant context.',
    // Masked: this often runs on a screen share during a customer demo.
    probe: () => {
      const tenant = probe('az account show --query tenantId -o tsv');
      return tenant ? tenant.slice(0, 8) + '-...' : null;
    },
    ok: v => !!v,
    install: 'az login --allow-no-subscriptions',
  },
  {
    key: 'git',
    label: 'Git',
    required: true,
    why: 'Used to scaffold starter agents from Agent365-Samples.',
    probe: () => firstVersion(probe('git --version')),
    ok: v => !!v,
    install: isWin ? 'winget install --id Git.Git -e' : 'brew install git',
  },
  {
    key: 'pwsh',
    label: 'PowerShell 7+',
    required: false,
    why: 'Some a365 setup fallbacks emit PowerShell for an admin to run.',
    probe: () => firstVersion(probe('pwsh --version')),
    ok: v => majorOf(v) >= 7,
    install: isWin
      ? 'winget install --id Microsoft.PowerShell -e'
      : 'brew install --cask powershell',
  },
  {
    key: 'python',
    label: 'Python 3.10+',
    required: false,
    why: 'Only for Python agents (LangChain, OpenAI Agents SDK, Google ADK).',
    probe: () => firstVersion(probe(isWin ? 'python --version' : 'python3 --version')),
    ok: v => {
      if (!v) return false;
      const parts = v.split('.').map(Number);
      return parts[0] > 3 || (parts[0] === 3 && parts[1] >= 10);
    },
    install: isWin
      ? 'winget install --id Python.Python.3.12 -e'
      : 'brew install python@3.12',
  },
];

// -- Run the checks ----------------------------------------------------------

const results = CHECKS.map(check => {
  let value = null;
  try { value = check.probe(); } catch { value = null; }
  return {
    key: check.key,
    label: check.label,
    required: check.required,
    why: check.why,
    value,
    passed: check.ok(value),
    install: check.install,
  };
});

const missingRequired = results.filter(r => r.required && !r.passed);
const missingOptional = results.filter(r => !r.required && !r.passed);

// -- Report ------------------------------------------------------------------

if (asJson) {
  process.stdout.write(JSON.stringify({
    ok: missingRequired.length === 0,
    platform: process.platform,
    results,
  }, null, 2) + '\n');
  process.exit(missingRequired.length === 0 ? 0 : 1);
}

const ESC = String.fromCharCode(27);
const GREEN = ESC + '[32m';
const RED = ESC + '[31m';
const YELLOW = ESC + '[33m';
const DIM = ESC + '[2m';
const BOLD = ESC + '[1m';
const RESET = ESC + '[0m';

const useColor = Boolean(process.stdout.isTTY) && !process.env.NO_COLOR;
const paint = (code, text) => (useColor ? code + text + RESET : text);

console.log('');
console.log(paint(BOLD, 'Agent 365 Onboarding Kit -- prerequisite check'));
console.log('');

const width = results.reduce((max, r) => Math.max(max, r.label.length), 0);

for (const r of results) {
  if (quiet && r.passed) continue;
  let mark;
  if (r.passed) mark = paint(GREEN, ' ok ');
  else if (r.required) mark = paint(RED, 'MISS');
  else mark = paint(YELLOW, 'opt ');
  const detail = paint(DIM, r.passed ? (r.value || '') : r.why);
  console.log('  [' + mark + '] ' + r.label.padEnd(width) + '  ' + detail);
}

if (missingRequired.length || missingOptional.length) {
  console.log('');
  console.log(paint(BOLD, 'To install what is missing:'));
  console.log('');
  for (const r of missingRequired.concat(missingOptional)) {
    const tag = r.required ? paint(RED, 'required') : paint(YELLOW, 'optional');
    console.log('  ' + r.label + ' (' + tag + ')');
    console.log(paint(DIM, '      ' + r.install));
  }
}

console.log('');
if (missingRequired.length === 0) {
  console.log(paint(GREEN, '  All required prerequisites are present.'));
  console.log('');
  process.exit(0);
}

const n = missingRequired.length;
console.log(paint(RED, '  ' + n + ' required prerequisite' + (n === 1 ? '' : 's') +
  ' missing -- install, then re-run.'));
console.log('');
process.exit(1);
