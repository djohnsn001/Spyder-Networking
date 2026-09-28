#!/usr/bin/env node

/**
 * Writes src/lib/legal/licenses.json: every package the app depends on in
 * production (the "dependencies" in package.json and everything they pull
 * in, not devDependencies), with its license name and license text. The
 * Open-source licenses screen in Settings shows this list — MIT, BSD and
 * Apache licenses require shipping their notices with the app.
 *
 * Plain Node, no extra packages (Zane's call, 2026-09-28). Re-run after
 * adding or upgrading dependencies:
 *
 *   npm run licenses
 *
 * Known gap: native libraries bundled inside some packages (e.g. React
 * Native's C++ dependencies) keep their notices inside those packages and
 * aren't listed separately here.
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const OUTPUT = path.join(ROOT, 'src', 'lib', 'legal', 'licenses.json');
const LICENSE_FILE = /^(licen[cs]e|copying|notice)(\.|-|_|$)/i;

// Find a package the way Node does: in ./node_modules, then each parent's.
function resolvePackageDir(name, fromDir) {
  let dir = fromDir;
  while (true) {
    const candidate = path.join(dir, 'node_modules', name);
    if (fs.existsSync(path.join(candidate, 'package.json'))) return candidate;
    if (dir === ROOT || dir === path.dirname(dir)) return null;
    dir = path.dirname(dir);
  }
}

function licenseName(pkg) {
  if (typeof pkg.license === 'string') return pkg.license;
  if (pkg.license && typeof pkg.license.type === 'string') return pkg.license.type;
  if (Array.isArray(pkg.licenses)) {
    return pkg.licenses.map((l) => (typeof l === 'string' ? l : l.type)).filter(Boolean).join(' OR ');
  }
  return 'UNKNOWN';
}

function licenseText(dir) {
  const files = fs
    .readdirSync(dir)
    .filter((file) => LICENSE_FILE.test(file))
    .sort((a, b) => a.length - b.length); // LICENSE before LICENSE-THIRD-PARTY
  const texts = files
    .map((file) => {
      const full = path.join(dir, file);
      return fs.statSync(full).isFile() ? fs.readFileSync(full, 'utf8').trim() : null;
    })
    .filter(Boolean);
  return texts.length > 0 ? texts.join('\n\n') : null;
}

function repositoryUrl(pkg) {
  const repo = typeof pkg.repository === 'string' ? pkg.repository : pkg.repository?.url;
  const url = repo || pkg.homepage || null;
  return url ? url.replace(/^git\+/, '').replace(/\.git$/, '') : null;
}

const rootPkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
const queue = Object.keys(rootPkg.dependencies ?? {}).map((name) => ({ name, fromDir: ROOT }));
const packages = new Map(); // "name@version" -> entry
const missing = new Set();

while (queue.length > 0) {
  const { name, fromDir } = queue.shift();
  const dir = resolvePackageDir(name, fromDir);
  if (!dir) {
    missing.add(name);
    continue;
  }
  const pkg = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));
  const key = `${pkg.name}@${pkg.version}`;
  if (packages.has(key)) continue;

  packages.set(key, {
    name: pkg.name,
    version: pkg.version,
    license: licenseName(pkg),
    repository: repositoryUrl(pkg),
    text: licenseText(dir),
  });

  // Peer dependencies are installed by someone else; include them only if
  // they're actually present.
  const next = {
    ...(pkg.dependencies ?? {}),
    ...(pkg.optionalDependencies ?? {}),
    ...(pkg.peerDependencies ?? {}),
  };
  for (const dep of Object.keys(next)) {
    if (pkg.peerDependencies?.[dep] && !resolvePackageDir(dep, dir)) continue;
    queue.push({ name: dep, fromDir: dir });
  }
}

const list = [...packages.values()]
  .filter((entry) => entry.name !== rootPkg.name)
  .sort((a, b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version));

// Many packages share identical license text; store each text once.
const texts = [];
const textIndex = new Map();
const entries = list.map(({ text, ...rest }) => {
  if (!text) return { ...rest, textId: null };
  if (!textIndex.has(text)) {
    textIndex.set(text, texts.length);
    texts.push(text);
  }
  return { ...rest, textId: textIndex.get(text) };
});

fs.writeFileSync(OUTPUT, JSON.stringify({ generatedAt: new Date().toISOString().slice(0, 10), packages: entries, texts }) + '\n');

// A short report, so anything unusual gets a human look.
const byLicense = {};
for (const entry of entries) byLicense[entry.license] = (byLicense[entry.license] ?? 0) + 1;
const copyleft = entries.filter((e) => /GPL|AGPL|LGPL|MPL|EPL|CDDL/i.test(e.license));
const unknown = entries.filter((e) => e.license === 'UNKNOWN');
const noText = entries.filter((e) => e.textId === null);

console.log(`Wrote ${entries.length} packages (${texts.length} distinct license texts) to ${path.relative(ROOT, OUTPUT)}`);
console.log('By license:', Object.entries(byLicense).sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k} ${v}`).join(', '));
if (copyleft.length) console.log('Copyleft / weak copyleft (check these):', copyleft.map((e) => `${e.name} (${e.license})`).join(', '));
if (unknown.length) console.log('No license field:', unknown.map((e) => e.name).join(', '));
if (noText.length) console.log(`${noText.length} packages ship no license file (the screen shows the license name only).`);
if (missing.size) console.log('Listed but not installed (optional/platform-specific):', [...missing].join(', '));
