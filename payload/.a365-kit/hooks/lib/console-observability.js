'use strict';

const fs = require('fs');
const path = require('path');
const { envFlagEnabled } = require('./env-config');

function topLevelDistroOptions(code) {
  // Ignore comments/string values and nested options: a365.enableConsoleExporters is not a distro option.
  const clean = code.replace(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\/\/[^\r\n]*|\/\*[\s\S]*?\*\//g,
    (token, offset, source) => {
      if (/^["']enableConsoleExporters["']$/.test(token) &&
          /^\s*:/.test(source.slice(offset + token.length))) return 'enableConsoleExporters';
      return ' '.repeat(token.length);
    });
  const options = [];
  for (const match of clean.matchAll(/\buseMicrosoftOpenTelemetry\s*\(\s*\{/g)) {
    let depth = 1;
    let outer = '';
    for (let index = match.index + match[0].length; index < clean.length && depth; index++) {
      const character = clean[index];
      if (character === '{') { depth++; outer += ' '; }
      else if (character === '}') { depth--; outer += ' '; }
      else if (depth === 1) outer += character;
    }
    if (depth === 0) options.push(outer);
  }
  return options.join('\n');
}

module.exports = function validateConsoleOnly({ language, files, envFiles }) {
  const read = filename => { try { return fs.readFileSync(filename, 'utf8'); } catch { return ''; } };
  const extensions = language === 'python' ? /\.py$/ : language === 'node' ? /\.(?:ts|js)$/ : /\.cs$/;
  const sources = files.filter(filename => extensions.test(filename)).map(read);
  const code = sources.join('\n');
  const packages = files.filter(filename =>
    /^(?:requirements\.txt|pyproject\.toml|package\.json)$/.test(path.basename(filename)) ||
    filename.endsWith('.csproj')).map(read).join('\n');
  const issues = [];
  const envEnabled = envFlagEnabled(envFiles, 'ENABLE_A365_OBSERVABILITY_EXPORTER');
  let hasInitialization;
  let hasConsole;
  let remoteEnabled;
  let hasPackage;

  if (language === 'python') {
    hasPackage = packages.includes('microsoft-opentelemetry');
    hasInitialization = code.includes('use_microsoft_opentelemetry');
    // The pinned bootstrap derives both options from the same validated environment flag.
    const pinnedEnvironmentWiring = sources.some(source =>
      /enabled\s*=\s*os\.getenv\(["']ENABLE_A365_OBSERVABILITY_EXPORTER["'],\s*["']false["']\)\.strip\(\)\.lower\(\)/.test(source) &&
      /a365_enable_observability_exporter\s*=\s*\(enabled\s*==\s*["']true["']\)/.test(source) &&
      /enable_console\s*=\s*\(enabled\s*==\s*["']false["']\)/.test(source));
    hasConsole = /\benable_console\s*=\s*True\b/.test(code) || (pinnedEnvironmentWiring && !envEnabled);
    remoteEnabled = /\ba365_enable_observability_exporter\s*=\s*True\b/.test(code) || envEnabled;
  } else if (language === 'node') {
    hasPackage = packages.includes('@microsoft/opentelemetry');
    hasInitialization = code.includes('useMicrosoftOpenTelemetry');
    hasConsole = /\benableConsoleExporters\s*:\s*true\b/.test(topLevelDistroOptions(code));
    const flags = [...code.matchAll(/\benableObservabilityExporter\s*:\s*(true|false)\b/g)]
      .map(match => match[1]);
    remoteEnabled = flags.includes('true') || (!flags.includes('false') && envEnabled);
  } else {
    hasPackage = packages.includes('Microsoft.OpenTelemetry');
    hasInitialization = code.includes('UseMicrosoftOpenTelemetry');
    hasConsole = /\bExportTarget\.Console\b/.test(code);
    remoteEnabled = /\bExportTarget\.Agent365\b/.test(code);
  }

  if (!hasPackage || !hasInitialization) issues.push('Console-only mode requires the unified Microsoft OpenTelemetry package and its initialization call');
  if (!hasConsole) issues.push('Console-only mode: no recognized enabled console exporter; configure the explicit console option for this SDK');
  if (remoteEnabled) issues.push('Console-only mode conflicts with an enabled Agent 365 exporter; disable the effective remote-export code/environment options');
  return issues;
};
