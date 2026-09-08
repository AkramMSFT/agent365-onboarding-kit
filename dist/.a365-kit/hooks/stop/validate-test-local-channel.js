#!/usr/bin/env node
// Agent 365 Onboarding Kit add-on validator: test-local-channel.
//
// The dev channel bypasses authentication, so the checks here are mostly about
// the things that keep it off the public path. Static file checks only -- no
// network, no build. Exit 0 {"ok":true} / 1 {"ok":false}.

'use strict';

const fs = require('fs');
const path = require('path');
const { scanProject } = require('../lib/project-scan');

const cwd = process.cwd();
const issues = [];
const read = p => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
const exists = p => { try { fs.accessSync(p); return true; } catch { return false; } };

// Maven and Gradle put sources deeper than scanProject's default maxDepth of 5.
const allFiles = scanProject(cwd, { maxDepth: 12 });
const sourceFiles = allFiles.filter(f => /\.(py|ts|js|cs|java)$/.test(f));
const anySource = (...patterns) => sourceFiles.some(f => {
  const c = read(f);
  return patterns.every(p => c.includes(p));
});

// Comment lines are dropped before any check that looks for a literal, because the
// reference module explains its own choice with "127.0.0.1, never 0.0.0.0" and a
// naive substring match would fail every correct project.
const codeOnly = text => text
  .split(/\r?\n/)
  .filter(line => !/^\s*(#|\/\/|\*|\/\*)/.test(line))
  .join('\n');

// Not installed at all -- nothing to validate. This add-on is optional.
if (!anySource('A365_DEV_CHANNEL')) {
  process.stdout.write(JSON.stringify({
    ok: true,
    note: 'No dev channel found -- test-local-channel not applied to this project',
  }));
  process.exit(0);
}

// 1. It must bind loopback explicitly. Binding the wildcard address would expose an
//    unauthenticated endpoint to the whole network.
if (!anySource('127.0.0.1')) {
  issues.push('The dev channel does not bind 127.0.0.1 explicitly -- an unauthenticated ' +
    'endpoint must never listen on the wildcard address');
}
const bindsWildcard = sourceFiles.some(f => {
  const c = read(f);
  return c.includes('A365_DEV_CHANNEL') && /["']0\.0\.0\.0["']/.test(codeOnly(c));
});
if (bindsWildcard) {
  issues.push('The file wiring the dev channel binds 0.0.0.0 -- an unauthenticated ' +
    'endpoint must listen on 127.0.0.1 only');
}

// 2. The forwarding-header refusal is the check that actually protects the endpoint.
//    A loopback test alone passes tunnelled traffic, because `devtunnel host` runs on
//    the developer's own machine and forwards from 127.0.0.1.
if (!anySource('x-forwarded-for') && !anySource('X-Forwarded-For')) {
  issues.push('The dev channel does not refuse requests carrying forwarding headers -- ' +
    'without this a tunnelled request reaches it looking local, because devtunnel ' +
    'forwards from 127.0.0.1. This is the check that protects the endpoint');
}

// 3. Off by default. This is the one env value in the kit that must not be true.
const envFiles = ['.env', '.env.example'].map(f => path.join(cwd, f)).filter(exists);
const envText = envFiles.map(read).join('\n');
if (envText.includes('A365_DEV_CHANNEL') &&
    /A365_DEV_CHANNEL\s*=\s*true/i.test(envText)) {
  issues.push('A365_DEV_CHANNEL is set to true in .env -- the dev channel bypasses ' +
    'authentication and must be off by default, enabled per session instead');
}

// 4. The production endpoint must still validate. If the dev channel was added by
//    removing the real check rather than adding a separate listener, that is the
//    one outcome this design exists to prevent.
if (anySource('/api/messages')) {
  const validatesInbound =
    anySource('Authorization') || anySource('authorization') ||
    anySource('jwt') || anySource('JWT') ||
    anySource('login.botframework.com');
  if (!validatesInbound) {
    issues.push('/api/messages no longer shows any inbound token validation -- the dev ' +
      'channel must be a separate listener, never a bypass on the production endpoint');
  }
}

// 5. A startup warning, so an operator who leaves the flag on can see it in the log.
if (!anySource('DEV CHANNEL ENABLED')) {
  issues.push('No startup warning found -- the dev channel should log loudly while it is ' +
    'enabled so it is not left on unnoticed');
}

if (issues.length) {
  process.stdout.write(JSON.stringify({ ok: false, reason: issues.join('; ') }));
  process.exit(1);
}
process.stdout.write(JSON.stringify({ ok: true }));
process.exit(0);
