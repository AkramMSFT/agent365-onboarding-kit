#!/usr/bin/env node
// Agent 365 Onboarding Kit -- upstream freshness check.
//
// Replaces the upstream plugin's scripts/check-version.js. That script assumed a
// plugin install and told the user to run `gh skill add microsoft/agent365-skills`,
// which is exactly the install path this kit exists to avoid. This version instead
// reports when Microsoft has published a newer agent365-skills release than the one
// this kit bundles, and points at re-downloading the kit.
//
// Wired as an optional SessionStart hook (see settings-fragment.json). A six-hour
// cache avoids repeated network probes. Failed or offline checks stay silent,
// and a short deadline keeps the notice from holding up a session.

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');

const CACHE_TTL_MS = 6 * 60 * 60 * 1000;
const FETCH_TIMEOUT_MS = 1500;

const manifestPath = path.join(__dirname, 'KIT-VERSION.json');

let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8').replace(/^\uFEFF/, ''));
} catch {
  process.exit(0); // no manifest -> nothing to compare, stay silent
}

if (!manifest || typeof manifest !== 'object') process.exit(0);
const bundled = parseVersion(manifest.upstreamVersion);
if (!bundled) process.exit(0);
const bundledUpstream = bundled.text;
const kitVersion = typeof manifest.kitVersion === 'string' ? manifest.kitVersion : 'unknown';

function parseVersion(value) {
  if (typeof value !== 'string') return null;
  const text = value.trim().replace(/^v/, '');
  const match = text.match(/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/);
  if (!match) return null;
  const prerelease = match[4] ? match[4].split('.') : [];
  if (prerelease.some(part => /^\d+$/.test(part) && /^0\d/.test(part))) return null;
  return { text, core: match.slice(1, 4).map(BigInt), prerelease };
}

function compareVersions(left, right) {
  for (let i = 0; i < 3; i++) {
    if (left.core[i] !== right.core[i]) return left.core[i] > right.core[i] ? 1 : -1;
  }
  if (!left.prerelease.length || !right.prerelease.length) {
    return Math.sign(right.prerelease.length) - Math.sign(left.prerelease.length);
  }
  for (let i = 0; i < Math.max(left.prerelease.length, right.prerelease.length); i++) {
    const a = left.prerelease[i];
    const b = right.prerelease[i];
    if (a === b) continue;
    if (a === undefined) return -1;
    if (b === undefined) return 1;
    const numericA = /^\d+$/.test(a);
    const numericB = /^\d+$/.test(b);
    if (numericA && numericB) return BigInt(a) > BigInt(b) ? 1 : -1;
    if (numericA !== numericB) return numericA ? -1 : 1;
    return a > b ? 1 : -1;
  }
  return 0;
}

function cacheFilePath() {
  const root = process.env.XDG_CACHE_HOME
    || (process.platform === 'win32'
      ? process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local')
      : path.join(os.homedir(), '.cache'));
  return path.join(root, 'agent365-onboarding-kit', 'upstream-version.json');
}

function readCache() {
  try {
    const data = JSON.parse(fs.readFileSync(cacheFilePath(), 'utf8'));
    if (!data || !Number.isFinite(data.checkedAt)) return null;
    if (data.latestVersion !== null && !parseVersion(data.latestVersion)) return null;
    // Drop the cache if the bundled version changed (user re-downloaded the kit).
    if (data.bundledUpstream !== bundledUpstream) return null;
    const age = Date.now() - data.checkedAt;
    if (age < 0 || age > CACHE_TTL_MS) return null;
    return data;
  } catch {
    return null;
  }
}

function writeCache(latestVersion) {
  try {
    const target = cacheFilePath();
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, JSON.stringify({
      checkedAt: Date.now(),
      bundledUpstream,
      latestVersion,
    }) + '\n', 'utf8');
  } catch {
    // cache write failures are non-fatal
  }
}

function fetchLatest() {
  return new Promise(resolve => {
    let child;
    let settled = false;
    const finish = value => {
      if (settled) return;
      settled = true;
      clearTimeout(deadline);
      resolve(value);
    };
    // Do not leave pipe handles (or a stuck CLI) keeping this optional hook alive.
    const deadline = setTimeout(() => {
      if (child) {
        child.kill('SIGKILL');
        child.stdout?.destroy();
        child.stderr?.destroy();
        child.unref?.();
      }
      finish(null);
    }, FETCH_TIMEOUT_MS + 250);
    try {
      child = execFile('gh', ['release', 'view', '--repo', 'microsoft/agent365-skills', '--json', 'tagName', '-q', '.tagName'], {
        encoding: 'utf8',
        timeout: FETCH_TIMEOUT_MS,
        killSignal: 'SIGKILL',
        windowsHide: true,
        env: { ...process.env, GH_PROMPT_DISABLED: '1', GIT_TERMINAL_PROMPT: '0' },
      }, (error, raw) => finish(error ? null : parseVersion(raw)?.text || null));
    } catch {
      finish(null);
    }
  });
}

async function main() {
  const cached = readCache();
  const latest = cached ? cached.latestVersion : await fetchLatest();
  // Cache failed probes as well, so offline sessions do not repeatedly wait on gh.
  if (!cached) writeCache(latest);
  const version = parseVersion(latest);
  if (!version || compareVersions(version, bundled) <= 0) return;

  console.log('> [!NOTE]');
  console.log('> **Newer Agent 365 skills available upstream.** This kit (v' + kitVersion +
    ') bundles agent365-skills v' + bundledUpstream + '; Microsoft has published v' + latest + '.');
  console.log('> The bundled skills still work. To pick up the newer ones, run');
  console.log('> `./agent365-kit.ps1 -Update` (Windows) or `./agent365-kit.sh --update` (macOS/Linux)');
  console.log('> in this project -- it replaces only the kit\'s own files.');
}

main().catch(() => {}); // Freshness notices must never fail a session.
