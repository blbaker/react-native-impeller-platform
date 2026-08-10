'use strict';
// `npx react-native run-impeller`
//
// Builds a bundle with Metro (platform=impeller) and launches the engine binary,
// passing the bundle as an ABSOLUTE path. PLAN D5: the engine has NO CWD probe and
// no fallback bundle location -- if the path is wrong we want a loud failure, not a
// stale bundle rendered from some other directory.

const fs = require('fs');
const path = require('path');
const {spawnSync} = require('child_process');
const {resolveEngine} = require('../resolve');

function readAppConfig(root) {
  const appJson = path.join(root, 'app.json');
  if (fs.existsSync(appJson)) {
    const j = JSON.parse(fs.readFileSync(appJson, 'utf8'));
    if (j.name) return j;
  }
  const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  return {name: pkg.name};
}

function bundle(root, {dev, entryFile, outDir, log, cliBin}) {
  fs.mkdirSync(outDir, {recursive: true});
  const out = path.join(outDir, 'index.impeller.bundle');
  const args = [
    cliBin || require.resolve('@react-native-community/cli/build/bin.js', {paths: [root]}),
    'bundle',
    '--platform',
    'impeller',
    '--dev',
    String(Boolean(dev)),
    '--entry-file',
    entryFile,
    '--bundle-output',
    out,
    '--assets-dest',
    path.join(outDir, 'assets'),
  ];
  log(`bundling: node ${args.slice(1).join(' ')}`);
  const r = spawnSync(process.execPath, args, {cwd: root, stdio: 'inherit'});
  if (r.status !== 0) {
    throw new Error(`Metro bundle failed with exit code ${r.status}`);
  }
  if (!fs.existsSync(out)) {
    throw new Error(`Metro reported success but produced no bundle at ${out}`);
  }
  return out;
}

function runImpeller(argv = [], config, options = {}) {
  const root = (config && config.root) || process.cwd();
  const log = options.log || console.log;
  const dev = !argv.includes('--release');
  const entryFile = options.entryFile || 'index.js';
  const outDir = path.join(root, 'impeller', 'build');

  const app = readAppConfig(root);
  const bundlePath = options.bundlePath || bundle(root, {dev, entryFile, outDir, log, cliBin: options.cliBin});
  const {binary, source, packageName} = resolveEngine();
  log(`engine: ${binary} (${source}${packageName ? ` -- ${packageName}` : ''})`);

  const engineArgs = ['--bundle', path.resolve(bundlePath), '--app-name', app.name, ...argv.filter((a) => a !== '--release')];
  if (options.dryRun) return {binary, engineArgs, bundlePath};

  const r = spawnSync(binary, engineArgs, {cwd: root, stdio: 'inherit'});
  if (r.error) throw r.error;
  process.exitCode = r.status === null ? 1 : r.status;
  return {binary, engineArgs, bundlePath, status: r.status};
}

module.exports = {runImpeller, bundle};
