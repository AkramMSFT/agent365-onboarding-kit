#!/usr/bin/env node
// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
/**
 * path-guard.js — PreToolUse hook
 *
 * Blocks Write and Edit calls that target files outside the agent project
 * directory or inside the plugin directory itself.
 *
 * Claude Code passes the pending tool call as JSON on stdin:
 *   { "tool_name": "Write", "tool_input": { "file_path": "..." }, ... }
 *
 * Exit codes:
 *   0  → allow (session continues)
 *   2  → block (Claude is told the reason and must stop the tool call)
 */

const fs   = require('fs');
const path = require('path');

// Resolve existing ancestors before appending missing components: a nested new
// path may cross a junction or symlink even when its immediate parent is absent.
function safeRealpath(p) {
  let current = p;
  const suffix = [];
  for (;;) {
    try {
      return path.join(fs.realpathSync.native(current), ...suffix);
    } catch {
      const parent = path.dirname(current);
      if (parent === current) return p;
      suffix.unshift(path.basename(current));
      current = parent;
    }
  }
}

function isInside(root, target) {
  const relative = path.relative(root, target);
  return relative === '' ||
    (relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative));
}

// Prefer CLAUDE_PROJECT_DIR (set by the CLI to the user's project root) over
// process.cwd() — Claude may be invoked from a subdirectory of the agent project,
// and we don't want to block legitimate writes to the project root in that case.
const projectRoot = safeRealpath(path.resolve(
  process.env.CLAUDE_PROJECT_DIR || process.cwd()
));
// Without a plugin install CLAUDE_PLUGIN_ROOT is unset, which would switch this guard
// off. Fall back to the kit folder inside the project. Added by the Agent 365
// Onboarding Kit; see its NOTICE.md, section 3.
const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT
  ? safeRealpath(path.resolve(process.env.CLAUDE_PLUGIN_ROOT))
  : safeRealpath(path.join(projectRoot, '.a365-kit'));

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { raw += chunk; });
process.stdin.on('end', () => {
  let payload;
  try { payload = JSON.parse(raw); } catch { process.exit(0); }

  if (!payload || typeof payload !== 'object') process.exit(0);
  const { tool_name, tool_input } = payload;

  // Only guard file-write tools
  if (!['Write', 'Edit'].includes(tool_name)) process.exit(0);

  const filePath = tool_input && (tool_input.file_path || tool_input.path);
  if (!filePath) process.exit(0);

  const resolved = safeRealpath(path.resolve(filePath));

  // Block writes into the plugin directory
  if (pluginRoot && isInside(pluginRoot, resolved)) {
    process.stdout.write(JSON.stringify({
      decision: 'block',
      reason:
        `Path guard: refusing to write inside the Agent 365 kit folder (${pluginRoot}). ` +
        `Skills must only modify files inside the user's agent project.`,
    }));
    process.exit(2);
  }

  // Block writes outside the agent project directory
  if (!isInside(projectRoot, resolved)) {
    process.stdout.write(JSON.stringify({
      decision: 'block',
      reason:
        `Path guard: refusing to write outside the agent project directory. ` +
        `project=${projectRoot}, target=${resolved}`,
    }));
    process.exit(2);
  }

  process.exit(0);
});
