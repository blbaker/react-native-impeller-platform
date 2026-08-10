'use strict';
// Metro integration for the `impeller` platform.
//
// PLAN D5/D6: `withImpeller()` WRAPS the consumer's metro config -- it chains an
// existing `resolveRequest` instead of replacing it, and it appends to
// `resolver.platforms` instead of overwriting. A metro plugin that clobbers those
// silently breaks every other RN plugin the app uses.
//
// Shims are resolved from `__dirname`, so linked / installed / tarball layouts all
// work identically. Never CWD-relative.
//
// WHY REDIRECT BY RESOLVED PATH, NOT BY MODULE NAME
// -------------------------------------------------
// React Native imports its own internals RELATIVELY: `Libraries/Utilities/Platform`
// is reached as `require('./Platform')` from inside react-native, so a resolver
// keyed on the string 'react-native/Libraries/Utilities/Platform' NEVER fires. The
// P1 consumer gate caught exactly that: the bundle built fine and contained no shim.
// So: let the upstream resolver do its job, then inspect the file it landed on and
// swap it. The `SHIM_TARGETS` suffixes below are matched against that resolved path.

const path = require('path');

const SHIM_DIR = path.join(__dirname, 'shims');

// resolved-path suffix (posix) -> shim file in SHIM_DIR
const SHIM_TARGETS = {
  'react-native/Libraries/Utilities/Platform.js': 'Platform.impeller.js',
};

function toPosix(p) {
  return p.split(path.sep).join('/');
}

function shimForResolvedPath(filePath) {
  if (!filePath) return null;
  const posix = toPosix(filePath);
  for (const [suffix, shim] of Object.entries(SHIM_TARGETS)) {
    if (posix.endsWith(suffix)) return path.join(SHIM_DIR, shim);
  }
  return null;
}

function withImpeller(config = {}) {
  const resolver = config.resolver || {};
  const existingPlatforms = resolver.platforms || ['ios', 'android', 'native'];
  const platforms = existingPlatforms.includes('impeller')
    ? existingPlatforms
    : [...existingPlatforms, 'impeller'];

  const priorResolveRequest = resolver.resolveRequest;

  function resolveRequest(context, moduleName, platform) {
    const resolution = priorResolveRequest
      ? priorResolveRequest(context, moduleName, platform)
      : context.resolveRequest(context, moduleName, platform);

    if (platform !== 'impeller' || !resolution || resolution.type !== 'sourceFile') {
      return resolution;
    }
    const shim = shimForResolvedPath(resolution.filePath);
    return shim ? {type: 'sourceFile', filePath: shim} : resolution;
  }

  return {
    ...config,
    resolver: {...resolver, platforms, resolveRequest},
  };
}

module.exports = {withImpeller, shimForResolvedPath, SHIM_TARGETS, SHIM_DIR};
