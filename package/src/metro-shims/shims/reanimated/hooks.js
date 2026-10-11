'use strict';
// SC-26. Reanimated hooks for the stub. With no worklet plugin and no UI
// thread, an "updater" (useAnimatedStyle / useAnimatedProps) is a JS function
// re-run whenever a shared value it read changes; Animated components
// (component.js) subscribe to it and re-render.
const React = require('react');
const {onFrame, now} = require('./clock');
const {makeMutable, isAnimation, track} = require('./values');

const HANDLE = Symbol.for('rni.reanimated.handle');

function depsChanged(prev, next) {
  if (!next || !prev || prev.length !== next.length) return true;
  return next.some((d, i) => !Object.is(d, prev[i]));
}

class Updater {
  constructor() {
    this.subs = new Set();
    this.unsubs = [];
    this.inline = new Map();
    this.raw = {};
  }
  run(fn) {
    const {result, deps} = track(fn);
    this.unsubs.forEach((u) => u());
    this.unsubs = Array.from(deps, (sv) => sv._subscribe(() => {
      this.run(fn);
      this.notify();
    }));
    this.raw = result || {};
    this.startInline(this.raw, '');
  }
  // Inline animations, e.g. {opacity: withTiming(1)}: each key path gets its
  // own shared value, restarted every time the updater runs.
  startInline(obj, prefix) {
    for (const k of Object.keys(obj)) {
      const v = obj[k];
      const path = prefix + k;
      if (isAnimation(v)) {
        let sv = this.inline.get(path);
        if (!sv) {
          sv = makeMutable(v.toValue !== undefined ? v.toValue : 0);
          sv._subscribe(() => this.notify());
          this.inline.set(path, sv);
        }
        sv.value = v;
      } else if (k === 'transform' && Array.isArray(v)) {
        v.forEach((e, i) => e && typeof e === 'object' && this.startInline(e, `${path}.${i}.`));
      }
    }
  }
  resolve(obj, prefix) {
    const out = {};
    for (const k of Object.keys(obj)) {
      const v = obj[k];
      const path = prefix + k;
      if (isAnimation(v)) out[k] = this.inline.get(path).value;
      else if (k === 'transform' && Array.isArray(v)) out[k] = v.map((e, i) => (e && typeof e === 'object' ? this.resolve(e, `${path}.${i}.`) : e));
      else out[k] = v;
    }
    return out;
  }
  current() {
    return this.resolve(this.raw, '');
  }
  notify() {
    for (const fn of Array.from(this.subs)) fn();
  }
  subscribe(fn) {
    this.subs.add(fn);
    return () => this.subs.delete(fn);
  }
  dispose() {
    this.unsubs.forEach((u) => u());
    this.unsubs = [];
    for (const sv of this.inline.values()) sv._cancel();
    this.subs.clear();
  }
}

// The object handed to `style`: the current values (so a plain View still
// paints them) carrying a hidden handle Animated components subscribe to.
function snapshot(u) {
  return Object.defineProperty(u.current(), HANDLE, {value: u, enumerable: false});
}

function useUpdater(fn, deps) {
  const ref = React.useRef(null);
  if (!ref.current) ref.current = {u: new Updater(), deps: undefined, ran: false};
  const s = ref.current;
  if (!s.ran || depsChanged(s.deps, deps)) {
    s.ran = true;
    s.deps = deps;
    s.u.run(fn);
  }
  React.useEffect(() => () => s.u.dispose(), [s]);
  return snapshot(s.u);
}

const useAnimatedStyle = (fn, deps) => useUpdater(fn, deps);
const useAnimatedProps = (fn, deps) => useUpdater(fn, deps);

function useSharedValue(initial) {
  const ref = React.useRef(null);
  if (!ref.current) ref.current = makeMutable(initial);
  const sv = ref.current;
  React.useEffect(() => () => sv._cancel(), [sv]);
  return sv;
}

// Re-run `fn` (tracked) whenever deps change or a shared value it read changes.
function useTracked(fn, deps, onResult) {
  const ref = React.useRef(null);
  if (!ref.current) ref.current = {unsubs: [], deps: undefined, ran: false};
  const s = ref.current;
  s.fn = fn;
  s.onResult = onResult;
  const run = () => {
    const {result, deps: seen} = track(() => s.fn());
    s.unsubs.forEach((u) => u());
    s.unsubs = Array.from(seen, (sv) => sv._subscribe(run));
    s.onResult(result);
  };
  if (!s.ran || depsChanged(s.deps, deps)) {
    s.ran = true;
    s.deps = deps;
    run();
  }
  React.useEffect(() => () => s.unsubs.forEach((u) => u()), [s]);
}

function useDerivedValue(fn, deps) {
  const sv = useSharedValue(undefined);
  useTracked(fn, deps, (v) => {
    sv.value = v;
  });
  return sv;
}

function useAnimatedReaction(prepare, react, deps) {
  const prev = React.useRef(null);
  useTracked(prepare, deps, (v) => {
    const p = prev.current;
    prev.current = v;
    if (!Object.is(p, v)) react(v, p);
  });
}

function useFrameCallback(callback, autostart = true) {
  const cb = React.useRef(callback);
  cb.current = callback;
  const ref = React.useRef(null);
  if (!ref.current) {
    const fc = {isActive: false, callbackId: Math.floor(Math.random() * 1e9), stop: null};
    fc.setActive = (on) => {
      if (on === fc.isActive) return;
      fc.isActive = on;
      if (!on) return fc.stop && fc.stop();
      let first = null;
      let last = null;
      fc.stop = onFrame((t) => {
        if (first == null) first = t;
        cb.current({timestamp: t, timeSincePreviousFrame: last == null ? null : t - last, timeSinceFirstFrame: t - first});
        last = t;
        return fc.isActive;
      });
    };
    ref.current = fc;
  }
  const fc = ref.current;
  React.useEffect(() => {
    if (autostart) fc.setActive(true);
    return () => fc.setActive(false);
  }, [fc, autostart]);
  return fc;
}

function useAnimatedScrollHandler(handlers) {
  return React.useCallback((e) => {
    const ev = e && e.nativeEvent ? e.nativeEvent : e;
    if (typeof handlers === 'function') handlers(ev);
    else if (handlers && handlers.onScroll) handlers.onScroll(ev);
  }, [handlers]);
}

module.exports = {
  HANDLE, now,
  useAnimatedStyle, useAnimatedProps, useSharedValue, useDerivedValue,
  useAnimatedReaction, useFrameCallback, useAnimatedScrollHandler,
};
