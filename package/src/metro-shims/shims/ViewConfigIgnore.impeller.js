'use strict';
// desktop-input-gap item 6. ConditionallyIgnoredEventHandlers for 'impeller'.
//
// WHY THIS EXISTS: RN core's ViewConfigIgnore.js strips onClick/onPointerDown/
// onPointerUp/onPointerEnter/... out of BaseViewConfig's validAttributes
// unless Platform.OS === 'ios' (ConditionallyIgnoredEventHandlers returns the
// object UNCHANGED on ios, `undefined` on every other platform, including our
// own 'impeller'). A stripped validAttribute means React never forwards the
// onClick/onPointer* PROP into the native view config at all, so
// PointerEventsProcessor::shouldEmitPointerEvent reads an all-zero ViewEvents
// bitset and swallows the event before it reaches JS -- even though
// FabricHost dispatches a perfectly correct PointerEvent on the C++ side.
// NATIVE FIRES, JS NEVER HEARS. Measured 2026-09-30: a real --hover-after-frames
// run printed native `hover_enter`/`cursor=` lines while the fixture's JS
// onPointerEnter console.log never fired, with a clean exit and no error.
//
// NOT A DELEGATING WRAPPER. ViewConfigIgnore.js has no `.ios.js`/`.android.js`
// sibling, so BaseViewConfig.impeller.js's trick (require the sibling by its
// EXPLICIT platform extension, bypassing the redirect machinery) is
// unavailable here: requiring the bare specifier from inside this file would
// be redirected straight back to this same file by shimForResolvedPath
// (SHIM_TARGETS matches the RESOLVED path, not who asked), an infinite
// require cycle. So this reimplements the ~15 lines of real upstream logic
// instead of delegating to them; every caller on the impeller platform
// resolves to this one file, so the WeakSet stays globally consistent.
const ignoredViewConfigProps = new WeakSet();

function DynamicallyInjectedByGestureHandler(object) {
  ignoredViewConfigProps.add(object);
  return object;
}

// THE FIX: unconditionally honour onPointerDown/onPointerUp/onClick/... on
// the impeller platform, instead of upstream's `OS === 'ios' ? value :
// undefined`. See the file header for why stripping these is a native-fires/
// JS-never-hears bug, not a feature gate.
function ConditionallyIgnoredEventHandlers(value) {
  return value;
}

function isIgnored(value) {
  if (typeof value === 'object' && value != null) {
    return ignoredViewConfigProps.has(value);
  }
  return false;
}

module.exports = {
  DynamicallyInjectedByGestureHandler,
  ConditionallyIgnoredEventHandlers,
  isIgnored,
};
module.exports.DynamicallyInjectedByGestureHandler = DynamicallyInjectedByGestureHandler;
module.exports.ConditionallyIgnoredEventHandlers = ConditionallyIgnoredEventHandlers;
module.exports.isIgnored = isIgnored;
