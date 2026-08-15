'use strict';
// `npx react-native init-impeller`
//
// PLAN D5: SCAFFOLD, NOT HARDCODE. Everything app-specific is derived from the
// consumer's app.json/package.json at scaffold time. No "playground", no
// workspaceRoot, no monorepo assumptions, no CWD-relative runtime paths.

const fs = require('fs');
const path = require('path');

const TEMPLATE_DIR = path.join(__dirname, '..', '..', 'templates', 'app');

function readJson(p) {
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

function detectAppName(root) {
  const appJson = path.join(root, 'app.json');
  if (fs.existsSync(appJson)) {
    const j = readJson(appJson);
    if (j.name) return j.name;
  }
  const pkgJson = path.join(root, 'package.json');
  if (fs.existsSync(pkgJson)) {
    const j = readJson(pkgJson);
    if (j.name) return j.name;
  }
  throw new Error(
    'Cannot determine the app name: neither app.json nor package.json has a "name".\n' +
      'Run init-impeller from the root of a React Native app.'
  );
}

function detectDisplayName(root, fallback) {
  const appJson = path.join(root, 'app.json');
  if (fs.existsSync(appJson)) {
    const j = readJson(appJson);
    if (j.displayName) return j.displayName;
  }
  return fallback;
}

function render(text, vars) {
  return text.replace(/\{\{(\w+)\}\}/g, (m, k) => {
    if (!(k in vars)) throw new Error(`Template references unknown variable {{${k}}}`);
    return vars[k];
  });
}

function copyTemplate(srcDir, destDir, vars, {force, log}) {
  fs.mkdirSync(destDir, {recursive: true});
  for (const entry of fs.readdirSync(srcDir, {withFileTypes: true})) {
    const src = path.join(srcDir, entry.name);
    const outName = entry.name.replace(/^_/, '.').replace(/\.tmpl$/, '');
    const dest = path.join(destDir, outName);
    if (entry.isDirectory()) {
      copyTemplate(src, dest, vars, {force, log});
      continue;
    }
    if (fs.existsSync(dest) && !force) {
      log(`  skip   ${path.relative(process.cwd(), dest)} (exists, use --force)`);
      continue;
    }
    fs.writeFileSync(dest, render(fs.readFileSync(src, 'utf8'), vars));
    log(`  write  ${path.relative(process.cwd(), dest)}`);
  }
}

function ensureMetroConfig(root, {log}) {
  const p = path.join(root, 'metro.config.js');
  const wrapped = `const {withImpeller} = require('@react-native-impeller/core/src/metro-shims');`;
  if (!fs.existsSync(p)) {
    fs.writeFileSync(
      p,
      `${wrapped}\nconst {getDefaultConfig} = require('@react-native/metro-config');\n\nmodule.exports = withImpeller(getDefaultConfig(__dirname));\n`
    );
    log('  write  metro.config.js');
    return;
  }
  const existing = fs.readFileSync(p, 'utf8');
  if (existing.includes('withImpeller')) {
    log('  ok     metro.config.js already wraps withImpeller');
    return;
  }
  // Wrap, do not replace: preserve whatever the app already exports.
  const patched =
    `${wrapped}\n` +
    existing.replace(/module\.exports\s*=\s*/, 'const __impellerBase = ') +
    `\nmodule.exports = withImpeller(__impellerBase);\n`;
  fs.writeFileSync(p, patched);
  log('  patch  metro.config.js (wrapped existing export with withImpeller)');
}

function initImpeller(argv, config, options = {}) {
  const root = (config && config.root) || process.cwd();
  const log = options.log || console.log;
  const force = Boolean(options.force);

  const appName = detectAppName(root);
  const vars = {
    appName,
    displayName: detectDisplayName(root, appName),
  };

  log(`init-impeller: scaffolding impeller/ for app "${appName}"`);
  copyTemplate(TEMPLATE_DIR, path.join(root, 'impeller'), vars, {force, log});
  ensureMetroConfig(root, {log});
  log('Done. Next: npx react-native run-impeller');
  return {appName, dir: path.join(root, 'impeller')};
}

module.exports = {initImpeller, detectAppName, render, TEMPLATE_DIR};
