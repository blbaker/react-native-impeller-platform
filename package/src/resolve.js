'use strict';
// Locates the prebuilt Impeller engine binary for the current platform.
//
// Delivery model (PLAN D4): the main package declares every
// `@blbaker/react-native-impeller-platform-engine-<platform>-<arch>` as an OPTIONAL dependency.
// npm installs only the one matching the host, so a consumer never compiles C++.
//
// Rules this file enforces:
//   1. `IMPELLER_ENGINE_BINARY` env var wins  (local engine development).
//   2. Otherwise resolve the per-platform package from THIS file's location
//      (`__dirname`) FIRST -- install and tarball must both work, and an
//      installed copy must never be outranked by something in the CWD.
//   3. On failure, throw an error that NAMES the missing package. A resolver that
//      says "not found" without the package name costs the consumer an hour.
//   4. Refuse a version mismatch between the engine package and this package.
//      Silent lockstep drift produces ABI crashes that look like renderer bugs.
//
// ⛔ `__dirname` ALONE IS NOT ENOUGH UNDER link:/file: (P10, 2026-09-02)
//
// The original comment here said "never from CWD -- link, install and tarball
// must all work". The first two words were right and the last claim was not
// TESTED: no gate ever ran the resolver through a symlinked package, so the
// linked case was asserted in a comment and broken in fact.
//
// Under `file:`/`npm link`, node_modules/react-native-impeller-platform is a
// SYMLINK back to this source checkout. `__dirname` therefore lands in the
// checkout, whose node_modules does NOT contain the engine package -- the
// engine lives in the checkout's sibling `packages-engine/engine-<triple>/`,
// which is where tools/engine-build.sh writes it and which no node_modules
// walk from anywhere will ever reach. Reproduced: a linked consumer app with
// the engine package ALSO linked into its own node_modules still failed,
// because resolution started from the symlink TARGET, not the app.
//
// So the anchor list is ordered, not replaced:
//   a. __dirname                     -- installed + tarball. Unchanged, first.
//   b. INIT_CWD / process.cwd()      -- the consumer's own tree, which is what
//                                       __dirname stops pointing at under link:.
//   c. <checkout>/packages-engine/   -- the linked source tree's own build
//                                       output, read directly by path.
// (a) still wins in every shipped install, so this cannot change what a real
// consumer resolves. It only gives the linked case somewhere true to look.
//
// This is deliberately NOT "just set IMPELLER_ENGINE_BINARY in the app's
// script". Line 79 of this file already rules that out: a package that needs
// an env var to function has not shipped. That applies to our own dev loop
// too -- an env var in a downstream app's paint-proof script is a workaround
// that hides this defect instead of fixing it.

const fs = require('fs');
const path = require('path');

// ⛔ THIS SET IS A PROMISE, NOT A ROADMAP (P7, 2026-08-14)
//
// A triple listed here with no published engine package produces the WORST
// possible failure: npm silently skips a missing optionalDependency and exits
// 0, so the user gets a clean install with no engine, then hits the "Missing
// engine package" error below — which instructs them to install a package that
// does not exist. A good error message with an impossible instruction.
//
// So a triple joins this list when its engine package is BUILT, not when it is
// planned. `tools/ci-release-meta.sh` fails the build if the two ever disagree.
// darwin-arm64/darwin-x64/linux-arm64 belong here the moment P6 ships them.
const SUPPORTED = new Set([
  'linux-x64',
  'win32-x64',
  'darwin-arm64',
]);

function hostTriple(platform = process.platform, arch = process.arch) {
  return `${platform}-${arch}`;
}

function packageNameFor(triple) {
  return `@blbaker/react-native-impeller-platform-engine-${triple}`;
}

function binaryFileName(platform = process.platform) {
  return platform === 'win32' ? 'rn-impeller.exe' : 'rn-impeller';
}

function ownVersion() {
  return require('../package.json').version;
}

/**
 * Ordered list of places to look for the engine package's package.json.
 *
 * ⛔ ORDER IS THE WHOLE SAFETY ARGUMENT. __dirname is index 0, so for any
 * normally-installed consumer this function returns on the first candidate and
 * behaves exactly as it did before link: support existed. Everything after it
 * is reached ONLY when the __dirname walk found nothing -- i.e. only in the
 * case that used to throw.
 */
function engineCandidates(triple, opts) {
  const env = opts.env || process.env;
  const cwd = opts.cwd || process.cwd();
  const out = [];

  // (a) Installed / tarball. Unchanged, and always first.
  out.push({kind: 'resolve', from: __dirname, source: 'package'});

  // (b) The consumer's own tree. Under link:/file: this is the only anchor that
  //     still points at the app, because __dirname followed the symlink out of
  //     it. npm sets INIT_CWD to the directory the command was run from, which
  //     survives npm running scripts from elsewhere; process.cwd() covers a
  //     plain `node ...` invocation.
  const consumerRoots = [env.INIT_CWD, cwd].filter(Boolean);
  for (const root of consumerRoots) {
    out.push({kind: 'resolve', from: path.join(root, 'node_modules'), source: 'linked-consumer'});
  }

  // (c) The linked SOURCE CHECKOUT's own build output. package/src/resolve.js
  //     -> ../../packages-engine/engine-<triple>. This is a direct path probe,
  //     not a node_modules walk, because engine-build.sh writes the binary
  //     there and nothing ever installs it into a node_modules anywhere.
  out.push({
    kind: 'path',
    // The directory is named by the triple, not the package: the npm name is
    // scoped under a different prefix and does not match the folder.
    dir: path.join(__dirname, '..', '..', 'packages-engine', `engine-${triple}`),
    source: 'linked-checkout',
  });

  return out;
}

/**
 * @returns {{binary: string, source: string, packageName: string|null, version: string|null}}
 */
function resolveEngine(opts = {}) {
  const platform = opts.platform || process.platform;
  const arch = opts.arch || process.arch;
  const env = opts.env || process.env;
  const triple = hostTriple(platform, arch);

  const override = env.IMPELLER_ENGINE_BINARY;
  if (override) {
    if (!fs.existsSync(override)) {
      throw new Error(
        `IMPELLER_ENGINE_BINARY is set to "${override}" but no file exists there.\n` +
          'Unset it to fall back to the installed engine package.'
      );
    }
    return {binary: path.resolve(override), source: 'env', packageName: null, version: null};
  }

  if (!SUPPORTED.has(triple)) {
    // ⛔ DO NOT TELL A CONSUMER TO BUILD THE ENGINE.
    // This message used to lead with `export IMPELLER_ENGINE_BINARY=...`, which
    // reads as "the supported fix is to compile a C++ engine yourself" — a
    // 40-minute Hermes build, a native toolchain, and an env var the app now
    // depends on forever. That is contributor work leaking into a consumer
    // error path. A package that needs an env var to function has not shipped.
    //
    // Say what is true (this platform is not supported yet) and point at the
    // one place that will change when it is. The env var is still honoured and
    // still documented under contributing — it is simply not the answer we hand
    // to someone whose install just failed.
    throw new Error(
      `react-native-impeller-platform does not support ${triple} yet.\n` +
        `Supported: ${[...SUPPORTED].join(', ')}\n\n` +
        'Track or request platform support:\n' +
        '    https://github.com/blbaker/react-native-impeller-platform/issues\n'
    );
  }

  const pkgName = packageNameFor(triple);
  let pkgJsonPath = null;
  let source = null;
  const tried = [];
  for (const cand of engineCandidates(triple, {env, cwd: opts.cwd})) {
    if (cand.kind === 'resolve') {
      tried.push(cand.from);
      try {
        pkgJsonPath = require.resolve(`${pkgName}/package.json`, {paths: [cand.from]});
      } catch (e) {
        continue;
      }
    } else {
      const p = path.join(cand.dir, 'package.json');
      tried.push(cand.dir);
      if (!fs.existsSync(p)) continue;
      pkgJsonPath = p;
    }
    source = cand.source;
    break;
  }

  if (!pkgJsonPath) {
    throw new Error(
      `Missing engine package "${pkgName}".\n` +
        'It ships as an optional dependency of react-native-impeller-platform and should\n' +
        'been installed automatically. Install it explicitly:\n\n' +
        `    npm install ${pkgName}@${ownVersion()}\n\n` +
        // ⛔ SAY WHERE WE LOOKED. The old message named the package but not the
        // search path, so a linked checkout whose engine was simply never built
        // produced the same text as a genuinely broken install.
        'Looked in:\n' +
        tried.map((t) => `    ${t}`).join('\n') +
        '\n\nOr point IMPELLER_ENGINE_BINARY at a locally built engine.'
    );
  }

  const enginePkg = JSON.parse(fs.readFileSync(pkgJsonPath, 'utf8'));
  const expected = ownVersion();
  if (enginePkg.version !== expected) {
    throw new Error(
      `Engine version mismatch: ${pkgName}@${enginePkg.version} is installed but\n` +
        `react-native-impeller-platform@${expected} requires exactly ${expected}.\n` +
        'The engine C ABI is versioned in lockstep; mixed versions crash at runtime.\n\n' +
        `    npm install ${pkgName}@${expected}`
    );
  }

  const binary = path.join(path.dirname(pkgJsonPath), 'bin', binaryFileName(platform));
  if (!fs.existsSync(binary)) {
    throw new Error(
      `Engine package "${pkgName}" is installed but its binary is missing:\n  ${binary}\n` +
        // A linked checkout reaches this when the package.json is committed but
        // packages-engine/*/bin is gitignored and was never built. "Corrupt --
        // reinstall it" is the wrong instruction there, so name the real fix.
        (source === 'linked-checkout'
          ? `This is a LINKED SOURCE CHECKOUT, not an installed package. Build the engine:\n` +
            `    bash tools/engine-build.sh ${platform} ${arch}`
          : 'The package is corrupt -- reinstall it.')
    );
  }
  return {binary, source, packageName: pkgName, version: enginePkg.version};
}

module.exports = {
  resolveEngine,
  hostTriple,
  packageNameFor,
  binaryFileName,
  engineCandidates,
  SUPPORTED,
};
