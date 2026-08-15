'use strict';
// Locates the prebuilt Impeller engine binary for the current platform.
//
// Delivery model (PLAN D4): the main package declares every
// `@react-native-impeller/engine-<platform>-<arch>` as an OPTIONAL dependency.
// npm installs only the one matching the host, so a consumer never compiles C++.
//
// Rules this file enforces:
//   1. `IMPELLER_ENGINE_BINARY` env var wins  (local engine development).
//   2. Otherwise resolve the per-platform package from THIS file's location
//      (`__dirname`), never from CWD -- link, install and tarball must all work.
//   3. On failure, throw an error that NAMES the missing package. A resolver that
//      says "not found" without the package name costs the consumer an hour.
//   4. Refuse a version mismatch between the engine package and this package.
//      Silent lockstep drift produces ABI crashes that look like renderer bugs.

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
  return `@react-native-impeller/engine-${triple}`;
}

function binaryFileName(platform = process.platform) {
  return platform === 'win32' ? 'rn-impeller.exe' : 'rn-impeller';
}

function ownVersion() {
  return require('../package.json').version;
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
    // Name the escape hatch. A developer on an unsupported triple can very
    // often BUILD the engine (the port is source-available and the SDK ships
    // prebuilts for more platforms than we publish packages for); dead-ending
    // them with "unsupported" hides a path that works today.
    throw new Error(
      `@react-native-impeller/core has no published engine build for ${triple}.\n` +
        `Published: ${[...SUPPORTED].join(', ')}\n\n` +
        'If you can build the engine for this platform, point the resolver at it:\n\n' +
        '    export IMPELLER_ENGINE_BINARY=/path/to/rn-impeller\n'
    );
  }

  const pkgName = packageNameFor(triple);
  let pkgJsonPath;
  try {
    pkgJsonPath = require.resolve(`${pkgName}/package.json`, {paths: [__dirname]});
  } catch (e) {
    throw new Error(
      `Missing engine package "${pkgName}".\n` +
        'It ships as an optional dependency of @react-native-impeller/core and should\n' +
        'been installed automatically. Install it explicitly:\n\n' +
        `    npm install ${pkgName}@${ownVersion()}\n\n` +
        'Or point IMPELLER_ENGINE_BINARY at a locally built engine.'
    );
  }

  const enginePkg = JSON.parse(fs.readFileSync(pkgJsonPath, 'utf8'));
  const expected = ownVersion();
  if (enginePkg.version !== expected) {
    throw new Error(
      `Engine version mismatch: ${pkgName}@${enginePkg.version} is installed but\n` +
        `@react-native-impeller/core@${expected} requires exactly ${expected}.\n` +
        'The engine C ABI is versioned in lockstep; mixed versions crash at runtime.\n\n' +
        `    npm install ${pkgName}@${expected}`
    );
  }

  const binary = path.join(path.dirname(pkgJsonPath), 'bin', binaryFileName(platform));
  if (!fs.existsSync(binary)) {
    throw new Error(
      `Engine package "${pkgName}" is installed but its binary is missing:\n  ${binary}\n` +
        'The package is corrupt -- reinstall it.'
    );
  }
  return {binary, source: 'package', packageName: pkgName, version: enginePkg.version};
}

module.exports = {resolveEngine, hostTriple, packageNameFor, binaryFileName, SUPPORTED};
