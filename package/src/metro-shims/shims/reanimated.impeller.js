'use strict';
// ENG-19 (moved from HostApp's app-level metro-shims/reanimated-stub.js).
// INERT react-native-reanimated for the `impeller` platform.
//
// WHY: the engine vends no Reanimated / Worklets native module, so the real
// package cannot initialise, and an app that does not install it cannot even
// BUNDLE: react-native-css (NativeWind 5) require()s 'react-native-reanimated'
// from native/reanimated.js on every className render that carries a
// transition/animation, and Gluestack's motion parts import it at module top.
//
// WHAT IT DOES: every animated component is the plain RN component, every
// shared value is a plain {value} box, every animation helper returns its
// target, every layout-animation preset is a chainable no-op. Styles land at
// their final value with no motion. Resolved only when the app has NOT
// installed react-native-reanimated itself (see metro-shims/index.js).
const RN = require('react-native');

const id = (c) => c;

// Chainable layout-animation builder: FadeIn.duration(200).delay(50) etc. all
// return the same inert object.
const preset = new Proxy(function () {}, {
  get: (t, k) => (k === '__esModule' ? false : k === 'build' ? () => () => ({}) : () => preset),
  apply: () => preset,
});

const Animated = {
  View: RN.View,
  Text: RN.Text,
  Image: RN.Image,
  ScrollView: RN.ScrollView,
  FlatList: RN.FlatList,
  createAnimatedComponent: id,
};

const sharedValue = (v) => ({value: v, get: () => v, set: () => {}, modify: () => {}});
const Easing = new Proxy({}, {get: () => () => 'linear'});

module.exports = {
  __esModule: true,
  __impellerStub: true,
  default: Animated,
  createAnimatedComponent: id,
  // layout-animation presets Gluestack's parts reference
  FadeIn: preset,
  FadeOut: preset,
  FadeInUp: preset,
  FadeInDown: preset,
  FadeOutUp: preset,
  FadeOutDown: preset,
  ZoomIn: preset,
  ZoomOut: preset,
  SlideInDown: preset,
  SlideOutDown: preset,
  SlideInUp: preset,
  SlideOutUp: preset,
  SlideInLeft: preset,
  SlideOutLeft: preset,
  SlideInRight: preset,
  SlideOutRight: preset,
  Layout: preset,
  LinearTransition: preset,
  // hooks
  useSharedValue: sharedValue,
  useDerivedValue: (f) => sharedValue(f()),
  useAnimatedStyle: (f) => f(),
  useAnimatedProps: (f) => f(),
  useAnimatedRef: () => ({current: null}),
  useAnimatedReaction: () => {},
  useAnimatedScrollHandler: () => () => {},
  useReducedMotion: () => true,
  // animation helpers: land on the target immediately
  withTiming: (v) => v,
  withSpring: (v) => v,
  withDecay: (cfg) => (cfg && cfg.velocity) || 0,
  withDelay: (_d, v) => v,
  withRepeat: (v) => v,
  withSequence: (...vs) => vs[vs.length - 1],
  cancelAnimation: () => {},
  runOnJS: (f) => f,
  runOnUI: (f) => f,
  interpolate: (x, input, output) => {
    if (!Array.isArray(input) || !Array.isArray(output) || input.length < 2) return x;
    const [a, b] = input;
    const [c, d] = output;
    return b === a ? c : c + ((x - a) * (d - c)) / (b - a);
  },
  Extrapolation: {CLAMP: 'clamp', EXTEND: 'extend', IDENTITY: 'identity'},
  ReduceMotion: {System: 'system', Always: 'always', Never: 'never'},
  Easing,
  // CSS-animation timing helpers react-native-css reads
  cubicBezier: () => 'ease',
  steps: () => 'linear',
};
