#!/usr/bin/env node
// Agent 365 Onboarding Kit -- upstream freshness check.
//
// Replaces the upstream plugin's scripts/check-version.js. That script assumed a
// plugin install and told the user to run `gh skill add microsoft/agent365-skills`,
// which is exactly the install path this kit exists to avoid. This version instead
// reports when Microsoft has published a newer agent365-skills release than the one
// this kit bundles, and points at re-downloading the kit.
//
// Wired as an optional SessionStart hook (see settings-fragment.json). Silent when
// up to date, when `gh` is unavailable, or when offline -- it must never be noisy
// and never block a session.

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync } = require('child_process');

const FALLBACK_TTL_MS = 6 * 60 * 60 * 1000; // 6h, used only when the live call fails

const manifestPath = path.join(__dirname, 'KIT-VERSION.json');

let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
} catch {
  process.exit(0); // no manifest -> nothing to compare, stay silent
}

const bundledUpstream = manifest.upstreamVersion;
const kitVersion = manifest.kitVersion;
if (!bundledUpstream) process.exit(0);

function cacheFilePath() {
  const dir = process.env.XDG_CACHE_HOME
    || (process.platform === 'win32'
      ? path.join(os.homedir(), 'AppData', 'Local', 'agent365-onboarding-kit')
      : path.join(os.homedir(), '.cache', 'agent365-onboarding-kit'));
  return path.join(dir, 'upstream-version.json');
}

function readCache() {
  try {
    const data = JSON.parse(fs.readFileSync(cacheFilePath(), 'utf8'));
    if (typeof data.checkedAt !== 'number') return null;
    if (typeof data.latestVersion !== 'string') return null;
    // Drop the cache if the bundled version changed (user re-downloaded the kit).
    if (data.bundledUpstream && data.bundledUpstream !== bundledUpstream) return null;
    if (Date.now() - data.checkedAt > FALLBACK_TTL_MS) return null;
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
  try {
    const raw = execSync(
      'gh release view --repo microsoft/agent365-skills --json tagName -q .tagName',
      { timeout: 5000, stdio: ['pipe', 'pipe', 'pipe'] }
    ).toString().trim();
    return raw.replace(/^v/, '');
  } catch {
    return null;
  }
}

let latest = fetchLatest();
if (latest) {
  writeCache(latest);
} else {
  const cached = readCache();
  if (cached) latest = cached.latestVersion;
}

if (latest && latest !== bundledUpstream) {
  console.log('> [!NOTE]');
  console.log('> **Newer Agent 365 skills available upstream.** This kit (v' + kitVersion +
    ') bundles agent365-skills v' + bundledUpstream + '; Microsoft has published v' + latest + '.');
  console.log('> The bundled skills still work. To pick up the newer ones, run');
  console.log('> `./agent365-kit.ps1 -Update` (Windows) or `./agent365-kit.sh --update` (macOS/Linux)');
  console.log('> in this project -- it replaces only the kit\'s own files.');
}
