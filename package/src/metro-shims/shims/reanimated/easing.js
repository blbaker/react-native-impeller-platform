'use strict';
// SC-26. Easing for the reanimated stub: RN's own Easing (the same curves
// Reanimated ships) plus steps, and the CSS timing keywords react-native-css
// passes through animation/transition timing functions.
const {Easing: RNEasing} = require('react-native');

function steps(n = 10, roundToNextStep = true) {
  const count = Math.max(1, Math.floor(n));
  return (t) => {
    const v = Math.min(Math.max(t, 0), 1) * count;
    return (roundToNextStep ? Math.ceil(v) : Math.floor(v)) / count;
  };
}

const Easing = {...RNEasing, steps};

const CSS = {
  linear: RNEasing.linear,
  ease: RNEasing.bezier(0.25, 0.1, 0.25, 1),
  'ease-in': RNEasing.bezier(0.42, 0, 1, 1),
  'ease-out': RNEasing.bezier(0, 0, 0.58, 1),
  'ease-in-out': RNEasing.bezier(0.42, 0, 0.58, 1),
  'step-start': steps(1, true),
  'step-end': steps(1, false),
};

// CSS cubic-bezier(): react-native-css calls this and puts the result in the
// style's timing function.
function cubicBezier(x1, y1, x2, y2) {
  return RNEasing.bezier(x1, y1, x2, y2);
}

// CSS steps(n, jump-start|start|jump-end|end).
function cssSteps(n, position) {
  return steps(n, position === 'start' || position === 'jump-start');
}

// A timing function as it arrives in a style or an animation config: a
// function, Reanimated's {factory} form, or a CSS keyword (default ease).
function toEasing(fn, fallback = CSS.ease) {
  if (typeof fn === 'function') return fn;
  if (fn && typeof fn.factory === 'function') return fn.factory();
  if (typeof fn === 'string' && CSS[fn]) return CSS[fn];
  return fallback;
}

module.exports = {Easing, cubicBezier, cssSteps, toEasing};
