// Fails when an example's dependency files point anywhere but the public registries,
// so a clone installs on any machine and no private feed name is published.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'examples');
const problems = [];
const walk = dir => fs.readdirSync(dir, { withFileTypes: true }).flatMap(e =>
  ['node_modules', 'bin', 'obj', 'target', '.venv', '__pycache__'].includes(e.name) ? [] :
  e.isDirectory() ? walk(path.join(dir, e.name)) : [path.join(dir, e.name)]);

for (const file of walk(root)) {
  const rel = path.relative(path.dirname(root), file).split(path.sep).join('/');
  const name = path.basename(file).toLowerCase();
  const text = () => fs.readFileSync(file, 'utf8');

  if (name === 'package-lock.json') {
    for (const [key, pkg] of Object.entries(JSON.parse(text()).packages ?? {})) {
      if (pkg.resolved && !pkg.resolved.startsWith('https://registry.npmjs.org/')) problems.push(`${rel}: ${key} resolves from ${new URL(pkg.resolved).host}`);
      if (pkg.integrity && !pkg.integrity.startsWith('sha512-')) problems.push(`${rel}: ${key} has a weak integrity hash`);
    }
  } else if (name === 'cargo.lock') {
    for (const m of text().matchAll(/^source = "([^"]+)"/gm)) {
      if (m[1] !== 'registry+https://github.com/rust-lang/crates.io-index') problems.push(`${rel}: source ${m[1]}`);
    }
  } else if (/^requirements.*\.txt$/.test(name) || name === 'pyproject.toml' || name === 'pip.conf' || name === 'pip.ini') {
    for (const m of text().matchAll(/(--(?:extra-)?index-url|--trusted-host|index-url\s*=)\s*\S*/g)) problems.push(`${rel}: ${m[0]}`);
  } else if (name === 'nuget.config') {
    for (const m of text().matchAll(/<add\s+[^>]*value="(https?:[^"]+)"/g)) {
      if (!m[1].startsWith('https://api.nuget.org/')) problems.push(`${rel}: NuGet source ${m[1]}`);
    }
  } else if (name === 'pom.xml') {
    for (const m of text().matchAll(/<url>(https?:[^<]+)<\/url>/g)) {
      if (/\/(repository|maven|artifactory|nexus|_packaging)\b/i.test(m[1]) && !m[1].startsWith('https://repo.maven.apache.org/')) problems.push(`${rel}: repository ${m[1]}`);
    }
  } else if (name === '.npmrc' || name === '.yarnrc' || name === '.yarnrc.yml') {
    problems.push(`${rel}: registry configuration file in an example`);
  }
}

for (const file of walk(root)) {
  if (/\.(json|txt|toml|xml|lock|config|mod|sum)$/i.test(file) && /pkgs\.(dev\.azure|visualstudio)\.com|packagefeedproxy|\/_packaging\//i.test(fs.readFileSync(file, 'utf8'))) {
    problems.push(`${path.relative(path.dirname(root), file).split(path.sep).join('/')}: private package feed URL`);
  }
}

if (problems.length) {
  console.error(`${problems.length} example dependency problem(s):\n  ${[...new Set(problems)].join('\n  ')}`);
  process.exit(1);
}
console.log('example dependencies resolve from public registries only');
