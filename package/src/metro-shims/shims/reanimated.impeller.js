'use strict';
// ENG-19 (moved from HostApp's app-level metro-shims/reanimated-stub.js).
// react-native-reanimated for the `impeller` platform.
//
// WHY: the engine vends no Reanimated / Worklets native module, so the real
// package cannot initialise, and an app that does not install it cannot even
// BUNDLE: react-native-css (NativeWind 5) require()s 'react-native-reanimated'
// from native/reanimated.js on every className render that carries a
// transition/animation, and Gluestack's motion parts import it at module top.
//
// WHAT IT DOES (SC-26): animated components are wrappers that re-render on a
// JS-thread clock, shared values and with* helpers really animate, and
// react-native-css transitions / animate-* move. Layout-animation presets stay
// chainable no-ops. Resolved only when the app has NOT
// installed react-native-reanimated itself (see metro-shims/index.js).
const RN = require('react-native');
const {createAnimatedComponent: animated} = require('./reanimated/component');
const hooks = require('./reanimated/hooks');
const values = require('./reanimated/values');
const {Easing: StubEasing, cubicBezier, cssSteps} = require('./reanimated/easing');
const {interpolate: interp} = require('./reanimated/interpolate');

// Chainable layout-animation builder: FadeIn.duration(200).delay(50) etc. all
// return the same inert object.
const preset = new Proxy(function () {}, {
  get: (t, k) => (k === '__esModule' ? false : k === 'build' ? () => () => ({}) : () => preset),
  apply: () => preset,
});

const Animated = {
  View: animated(RN.View),
  Text: animated(RN.Text),
  Image: animated(RN.Image),
  ScrollView: animated(RN.ScrollView),
  FlatList: animated(RN.FlatList),
  createAnimatedComponent: animated,
};

const sharedValue = (v) => ({value: v, get: () => v, set: () => {}, modify: () => {}});

module.exports = {
  __esModule: true,
  __impellerStub: true,
  default: Animated,
  createAnimatedComponent: animated,
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
  // hooks and animation helpers (JS-thread implementation, see ./reanimated/)
  useSharedValue: hooks.useSharedValue,
  useDerivedValue: hooks.useDerivedValue,
  useAnimatedStyle: hooks.useAnimatedStyle,
  useAnimatedProps: hooks.useAnimatedProps,
  useAnimatedRef: () => ({current: null}),
  useAnimatedReaction: hooks.useAnimatedReaction,
  useAnimatedScrollHandler: hooks.useAnimatedScrollHandler,
  useReducedMotion: () => false,
  withTiming: values.withTiming,
  withSpring: values.withSpring,
  withDecay: values.withDecay,
  withDelay: values.withDelay,
  withRepeat: values.withRepeat,
  withSequence: values.withSequence,
  cancelAnimation: values.cancelAnimation,
  runOnJS: (f) => f,
  runOnUI: (f) => f,
  interpolate: interp,
  Extrapolation: {CLAMP: 'clamp', EXTEND: 'extend', IDENTITY: 'identity'},
  ReduceMotion: {System: 'system', Always: 'always', Never: 'never'},
  Easing: StubEasing,
  // CSS-animation timing helpers react-native-css reads
  cubicBezier,
  steps: cssSteps,
};
