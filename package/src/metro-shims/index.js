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
  // P4. Alert.js is NOT a stub and resolves perfectly — it simply branches
  // itself out of existence: `if (ios) {...} else if (android) {...}` with no
  // else. On `impeller` the call never leaves JavaScript, so a flawless native
  // AlertManager is unreachable and nothing anywhere reports a problem. See
  // shims/Alert.impeller.js for the full note; this is a distinct failure from
  // the self-resolving RCTAlertManager.js stub below, and BOTH had to be fixed.
  'react-native/Libraries/Alert/Alert.js': 'Alert.impeller.js',
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
  // P4. `Libraries/Alert/RCTAlertManager.js` is a textbook instance: its entire
  // body is `export * from './RCTAlertManager'`, which on a platform with no
  // sibling extension resolves to ITSELF. `alertWithArgs` is then undefined and
  // `Alert.alert()` dies with "alertWithArgs is not a function" — pointing at
  // our AlertManager TurboModule, which is fine.
  //
  // Note the shape of the trap: the NATIVE module can be perfect and the
  // feature still 100% broken, because the JS never reaches it. That is why
  // the P4 gate asserts a native-side side-effect counter (alerts_shown) and
  // not just "the module is in the manifest".
  'react-native/Libraries/Alert/RCTAlertManager.js': 'RCTAlertManager.ios.js',
  // Same disease, same fix. Reached by fetch/XMLHttpRequest.
  'react-native/Libraries/Network/RCTNetworking.js': 'RCTNetworking.ios.js',
};

// ---------------------------------------------------------------------------
// ENG-01a. FILES THAT BRANCH THEMSELVES OUT OF EXISTENCE ON A CUSTOM PLATFORM
//
// A third failure shape, distinct from both lists above. The file resolves
// perfectly, imports perfectly, and RUNS -- and then does nothing, because its
// entire body is `if (ios) {...} else if (android) {...}` with no else. Nothing
// throws and nothing logs. Alert.js was the first (fixed by vendoring a shim);
// TextInput.js is the second and CANNOT be vendored, because it is ~1000 lines
// of stateful RN internals we would then own forever across RN bumps.
//
// So instead of replacing the file, we change the ANSWER IT GETS. When
// TextInput.js asks `Platform.OS`, and only when TextInput.js asks, it is told
// 'ios' -- the desktop-shaped arm, same rule as PLATFORM_FORKED above. Every
// other importer of Platform still gets 'impeller'.
//
// ⚠️ MATCHED ON THE *IMPORTER*, NOT ON THE RESOLVED FILE.
// The other two tables inspect what a request resolved TO. This one inspects
// who ASKED. Metro gives us that as `context.originModulePath`. Keying this on
// the resolved path instead would swap Platform for the entire bundle, which
// is the global lie this design exists to avoid.
const IOS_BRANCHED_IMPORTERS = {
  'react-native/Libraries/Components/TextInput/TextInput.js':
    'Platform.impeller-as-ios.js',
};

// The module specifier TextInput.js actually writes is RELATIVE
// (`import Platform from '../../Utilities/Platform'`), so this is checked
// against the RESOLVED Platform path, gated by the origin file.
const PLATFORM_MODULE_SUFFIX =
  'react-native/Libraries/Utilities/Platform.js';

function toPosix(p) {
  return p.split(path.sep).join('/');
}

function shimForOrigin(originModulePath, resolvedFilePath) {
  if (!originModulePath || !resolvedFilePath) return null;
  if (!toPosix(resolvedFilePath).endsWith(PLATFORM_MODULE_SUFFIX)) return null;
  const origin = toPosix(originModulePath);
  for (const [suffix, shim] of Object.entries(IOS_BRANCHED_IMPORTERS)) {
    if (origin.endsWith(suffix)) return path.join(SHIM_DIR, shim);
  }
  return null;
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
    // Origin-scoped first: it is the narrower rule, and the only one that can
    // return a DIFFERENT Platform than the global shim.
    const originShim = shimForOrigin(context.originModulePath, resolution.filePath);
    if (originShim) return {type: 'sourceFile', filePath: originShim};
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
  shimForOrigin,
  SHIM_TARGETS,
  PLATFORM_FORKED,
  IOS_BRANCHED_IMPORTERS,
  SHIM_DIR,
};
