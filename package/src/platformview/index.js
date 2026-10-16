'use strict';
// FP-44 — platform views (Flutter's PlatformViewLayer + ExternalViewEmbedder).
//
// <ImpellerPlatformView color="#00aa00" style={...} /> is a native OS child view
// (an X11 child window on linux windowed GL) that the engine positions, clips
// and stacks to the view's box every frame; RN content drawn after it in paint
// order is composited above it. This first native view is a solid colour.
// Translate and rect clips are composited; scale/rotate/skew are not (the view
// is placed at the transformed bounds and the engine logs
// `platform_view_unsupported`). Hosts without an embedder (darwin, Windows,
// headless) paint the colour in place.

const {processColor} = require('react-native');
const NativeComponentRegistry = require('react-native/Libraries/NativeComponent/NativeComponentRegistry');

const ImpellerPlatformView = NativeComponentRegistry.get('ImpellerPlatformView', () => ({
  uiViewClassName: 'ImpellerPlatformView',
  bubblingEventTypes: {},
  directEventTypes: {},
  validAttributes: {color: {process: processColor}},
}));

module.exports = {ImpellerPlatformView};
