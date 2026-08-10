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

// ---------------------------------------------------------------------------
// PLATFORM-FORKED RN FILES ("ios-stub disease")
//
// Some react-native modules exist ONLY as `.ios.js` / `.android.js`, with a
// bare `Foo.js` whose entire body is `import Foo from './Foo'; export default
// Foo;` — a re-export that relies on the platform extension resolving to a
// sibling. On a custom platform there is no sibling, so `./Foo` resolves to the
// file ITSELF, the circular import yields `undefined`, and the export is
// silently undefined.
//
// The failure surfaces far away and blames the renderer. Measured here:
// BaseViewConfig.js self-resolved, so `PlatformBaseViewConfig` was undefined and
// ViewConfig.js died with `Cannot read property 'bubblingEventTypes' of
// undefined` while mounting the first <View> — which reads like a broken Fabric
// component registration and is nothing of the sort.
//
// Fix: redirect the bare file to the iOS flavour, which is the desktop-shaped
// one (the Android variants reach for JNI-backed view managers). This REDIRECTS
// TO RN'S OWN FILE rather than vendoring a copy, so an RN bump carries its own
// content and cannot go stale.
const PLATFORM_FORKED = {
  'react-native/Libraries/NativeComponent/BaseViewConfig.js': 'BaseViewConfig.ios.js',
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
  for (const [suffix, sibling] of Object.entries(PLATFORM_FORKED)) {
    if (posix.endsWith(suffix)) {
      return path.join(path.dirname(filePath), sibling);
    }
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

module.exports = {
  withImpeller,
  shimForResolvedPath,
  SHIM_TARGETS,
  PLATFORM_FORKED,
  SHIM_DIR,
};
