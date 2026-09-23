'use strict';

const fs = require('fs');
const path = require('path');

function parseEnv(text) {
  const values = new Map();
  for (const line of text.split(/\r?\n/)) {
    const match = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
    if (!match) continue;
    const value = match[2].trim();
    const quoted = /^(['"`])(.*?)\1\s*(?:#.*)?$/.exec(value);
    values.set(match[1], quoted ? quoted[2] : value.split('#', 1)[0].trim());
  }
  return values;
}

function readEnvValue(filename, key) {
  try {
    return parseEnv(fs.readFileSync(filename, 'utf8')).get(key);
  } catch {
    return undefined;
  }
}

function selectEnvFiles(files) {
  // Generated hosts normally load the project's .env, not .env.example.
  const rootEnv = path.resolve(process.cwd(), '.env');
  const primary = files.find(filename => path.resolve(filename) === rootEnv);
  if (primary) return [primary];
  const concrete = files.filter(filename => !path.basename(filename).endsWith('.example'));
  return concrete.length ? concrete : files;
}

function envFlagEnabled(files, key) {
  const values = selectEnvFiles(files)
    .map(filename => readEnvValue(filename, key))
    .filter(value => value !== undefined);
  return values.length > 0 && values.every(value => value.toLowerCase() === 'true');
}

module.exports = { parseEnv, readEnvValue, selectEnvFiles, envFlagEnabled };
