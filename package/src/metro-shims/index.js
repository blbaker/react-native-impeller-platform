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

const fs = require('fs');
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
  // desktop-input-gap P0 item 1. Bare BaseViewConfig.js is ALSO covered by
  // the PLATFORM_FORKED ios-stub redirect below (it is a genuine ios-stub-
  // disease file, unrelated to this entry), but SHIM_TARGETS is consulted
  // FIRST in shimForResolvedPath -- see below -- so this entry wins and the
  // PLATFORM_FORKED one is inert for this specifier. Kept that way
  // deliberately (not removed from PLATFORM_FORKED) so it stays the ios-stub-
  // disease REFERENCE case the P2 gate's mutation suite targets, and this
  // shim is additive on top of it (see shims/BaseViewConfig.impeller.js for
  // why): the ios-stub-disease fix is still exactly what runs underneath.
  'react-native/Libraries/NativeComponent/BaseViewConfig.js':
    'BaseViewConfig.impeller.js',
  // desktop-input-gap item 6. RN core's ConditionallyIgnoredEventHandlers
  // strips onClick/onPointerDown/onPointerUp/... from validAttributes unless
  // Platform.OS === 'ios' -- see shims/ViewConfigIgnore.impeller.js for the
  // full "native fires, JS never hears" story.
  'react-native/Libraries/NativeComponent/ViewConfigIgnore.js':
    'ViewConfigIgnore.impeller.js',
  // parity item 7. TextInputState.js sends focus/blur commands only on ios/
  // android, behind a Platform.OS check Metro inlines to 'impeller' at build
  // time, so ref.focus()/ref.blur() never reached native. See the shim.
  'react-native/Libraries/Components/TextInput/TextInputState.js':
    'TextInputState.impeller.js',
  // parity item 12. Image.js self re-exports to undefined on impeller; in a
  // __DEV__ bundle that crashed LogBox on its first warning. SC-30: the shim
  // now mounts the real RCTImageView host component. See the shim.
  'react-native/Libraries/Image/Image.js': 'Image.impeller.js',
  // SC-18. Adds a fontFamily processor (array -> CSS stack); see the shim.
  'react-native/Libraries/Components/View/ReactNativeStyleAttributes.js':
    'ReactNativeStyleAttributes.impeller.js',
  // SC-24. Button branches on Platform.OS ios/android, both false here.
  'react-native/Libraries/Components/Button.js': 'Button.impeller.js',
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

// ---------------------------------------------------------------------------
// ENG-01c. MATCH ON THE ORIGIN *FOLDER*, NOT JUST THE FILE.
//
// The file table above is a lie in the presence of Metro's resolution cache.
// metro/src/node-haste/DependencyGraph.js resolveDependency() keys the cache on
// `(resolverOptions, originKey, targetKey, platform)` where, for a specifier
// that contains "/" (ours is `../../Utilities/Platform`), originKey is
// `path.dirname(originModulePath)` -- the origin FOLDER, not the file. It also
// splits targetKey by import kind (`\0esm` vs `\0cjs`). resolveRequest runs
// ONLY on a cache miss.
//
// Components/TextInput/ has three siblings importing ../../Utilities/Platform:
//   TextInput.js          (ESM import) -- must get as-ios or it mounts null
//   InputAccessoryView.js (ESM import) -- shares TextInput.js's exact cache key
//   TextInputState.js     (CJS require) -- its own cache bucket
// Because TextInput.js and InputAccessoryView.js share one ESM cache entry for
// the whole folder, whichever resolves first fills it for both. When
// InputAccessoryView wins, TextInput.js is handed the cached plain-impeller
// Platform without resolveRequest ever running for it, branches itself out of
// existence, and mounts no native field. Build order decides the winner, which
// is why it flaked ~15% here and 6/6 in the HostApp app.
//
// FIX: key the origin rule on the FOLDER. Every importer in
// Components/TextInput/ gets as-ios. This is forced, not chosen -- the shared
// ESM cache key means TextInput.js and InputAccessoryView.js CANNOT be given
// different answers. It is also correct:
//   - TextInputState.js only reads OS to pick focus/blur commands, and the
//     iOS commands are exactly what the native field TextInput.js now mounts
//     expects (previously, with plain impeller, focus/blur silently no-op'd).
//   - InputAccessoryView.js is iOS-only API. as-ios makes it try to mount
//     RCTInputAccessoryViewNativeComponent, which is NOT registered in
//     FabricHost -- but that path only runs if an app actually mounts
//     <InputAccessoryView>, the pre-fix code already leaked as-ios to it ~50%
//     of the time with no reported breakage, and registering that component is
//     a separate future ticket, not a regression introduced here.
const IOS_BRANCHED_ORIGIN_DIRS = {
  'react-native/Libraries/Components/TextInput': 'Platform.impeller-as-ios.js',
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
  // ENG-01c: folder-scoped fallback. Metro's resolution cache is keyed on the
  // origin FOLDER, so a file-only rule loses the race for siblings that share
  // the cache entry. Match the containing directory of the importer.
  const originDir = toPosix(path.dirname(originModulePath));
  for (const [dirSuffix, shim] of Object.entries(IOS_BRANCHED_ORIGIN_DIRS)) {
    if (originDir.endsWith(dirSuffix)) return path.join(SHIM_DIR, shim);
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

// parity item 20. Self re-export files redirected to their .ios.js sibling
// (see resolveRequest). Only files measured to break are listed; the others
// under Libraries/ are either already shimmed or render fine.
const SELF_REEXPORTS = [
  'react-native/Libraries/StyleSheet/PlatformColorValueTypes.js',
  'react-native/Libraries/Utilities/BackHandler.js',
  'react-native/Libraries/Components/AccessibilityInfo/legacySendAccessibilityEvent.js',
];

function selfReexportSibling(filePath) {
  const posix = toPosix(filePath);
  if (!SELF_REEXPORTS.some((rel) => posix.endsWith(rel))) return null;
  const ios = filePath.replace(/\.js$/, '.ios.js');
  return fs.existsSync(ios) ? ios : null;
}

// parity item 20. See shims/ReactNativeFeatureFlags.impeller.js.
const FEATURE_FLAGS_SUFFIX =
  'react-native/src/private/featureflags/ReactNativeFeatureFlags.js';
const FEATURE_FLAGS_SHIM = 'ReactNativeFeatureFlags.impeller.js';

// ENG-19. See resolveRequest and shims/reanimated.impeller.js.
const REANIMATED = 'react-native-reanimated';
const REANIMATED_SHIM = 'reanimated.impeller.js';

function withImpeller(config = {}) {
  const resolver = config.resolver || {};
  const existingPlatforms = resolver.platforms || ['ios', 'android', 'native'];
  const platforms = existingPlatforms.includes('impeller')
    ? existingPlatforms
    : [...existingPlatforms, 'impeller'];

  const priorResolveRequest = resolver.resolveRequest;

  function baseResolve(context, moduleName, platform) {
    return priorResolveRequest
      ? priorResolveRequest(context, moduleName, platform)
      : context.resolveRequest(context, moduleName, platform);
  }

  function resolveRequest(context, moduleName, platform) {
    // ENG-19. react-native-reanimated: the engine vends no Reanimated/Worklets
    // native module, and an app that does not install the package cannot even
    // bundle (react-native-css requires it from native/reanimated.js). When
    // the app has NOT installed it, resolve to the package's inert stub
    // (shims/reanimated.impeller.js). An app that installs the real package
    // keeps it: that is a deliberate choice, and hiding it would be a lie.
    if (platform === 'impeller' && moduleName === REANIMATED) {
      try {
        return baseResolve(context, moduleName, platform);
      } catch (error) {
        return {type: 'sourceFile', filePath: path.join(SHIM_DIR, REANIMATED_SHIM)};
      }
    }
    let resolution;
    try {
      resolution = baseResolve(context, moduleName, platform);
    } catch (error) {
      // parity item 20. RN ships some modules ONLY as .ios.js + .android.js
      // with no platform-neutral file, so resolving them for 'impeller'
      // THROWS. ReactDevToolsSettingsManager (reached from setUpReactDevTools
      // in every __DEV__ bundle) is one: no dev bundle could even be built.
      // Retry as ios, and ONLY on a throw: a module that resolves to an ios
      // stub exporting undefined is a different defect, and a blanket
      // redirect would hide it. (Moved here from HostApp's metro.config.js.)
      if (platform !== 'impeller') throw error;
      resolution = baseResolve(context, moduleName, 'ios');
    }

    if (platform !== 'impeller' || !resolution || resolution.type !== 'sourceFile') {
      return resolution;
    }
    // parity item 20. Self re-export files: RN ships a few `Foo.js` whose body
    // is `import Foo from './Foo'; export default Foo;`, meant to resolve
    // through a .ios.js/.android.js sibling. On impeller there is no sibling,
    // the import resolves back to ITSELF, and the default export is
    // undefined. Measured in HostApp (Gluestack Popover): BackHandler ("Cannot
    // read property 'addEventListener' of undefined") and
    // legacySendAccessibilityEvent ("0,s.default is not a function").
    const selfReexport = selfReexportSibling(resolution.filePath);
    if (selfReexport) return {type: 'sourceFile', filePath: selfReexport};
    // parity item 20. Feature-flags redirect (see the shim), except for the
    // shim's own require of the real module.
    const origin = toPosix(context.originModulePath || '');
    if (
      toPosix(resolution.filePath).endsWith(FEATURE_FLAGS_SUFFIX) &&
      !origin.endsWith('/' + FEATURE_FLAGS_SHIM)
    ) {
      return {type: 'sourceFile', filePath: path.join(SHIM_DIR, FEATURE_FLAGS_SHIM)};
    }
    // Origin-scoped first: it is the narrower rule, and the only one that can
    // return a DIFFERENT Platform than the global shim.
    const originShim = shimForOrigin(context.originModulePath, resolution.filePath);
    if (originShim) return {type: 'sourceFile', filePath: originShim};
    const shim = shimForResolvedPath(resolution.filePath);
    // A shim that wraps the real module requires it by path; do not loop it back.
    if (shim && origin === toPosix(shim)) return resolution;
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
  IOS_BRANCHED_ORIGIN_DIRS,
  SHIM_DIR,
};
