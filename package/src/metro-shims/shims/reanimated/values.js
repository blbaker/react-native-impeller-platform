'use strict';
// SC-26. Shared values and the with* animations of the reanimated stub, run
// on the JS thread by clock.js. An animation is a plain object with
// start(from, now) and frame(now) -> done; assigning one to sv.value runs it.
const {now, onFrame} = require('./clock');
const {Easing, toEasing} = require('./easing');
const {mix} = require('./interpolate');

const ANIM = Symbol.for('rni.reanimated.animation');
const isAnimation = (v) => v != null && typeof v === 'object' && v[ANIM] === true;

// Shared values read while a tracker is set are recorded (useAnimatedStyle /
// useDerivedValue re-run when one of them changes).
let tracker = null;
function track(fn) {
  const prev = tracker;
  const seen = new Set();
  tracker = seen;
  try {
    return {result: fn(), deps: seen};
  } finally {
    tracker = prev;
  }
}

class SharedValue {
  constructor(v) {
    this._value = v;
    this._anim = null;
    this._listeners = new Map();
    this._seq = 0;
  }
  get value() {
    if (tracker) tracker.add(this);
    return this._value;
  }
  set value(v) {
    this._anim = null;
    if (isAnimation(v)) {
      const anim = v;
      this._anim = anim;
      anim.start(this._value, now());
      onFrame((t) => {
        if (this._anim !== anim) return false;
        const done = anim.frame(t);
        this._write(anim.current);
        if (done) {
          this._anim = null;
          anim.finish(true);
        }
        return !done;
      });
      return;
    }
    this._write(v);
  }
  _write(v) {
    this._value = v;
    for (const fn of Array.from(this._listeners.values())) fn(v);
  }
  get() {
    return this.value;
  }
  set(v) {
    this.value = typeof v === 'function' ? v(this._value) : v;
  }
  modify(fn) {
    if (fn) this.value = fn(this._value);
  }
  addListener(id, fn) {
    this._listeners.set(id, fn);
  }
  removeListener(id) {
    this._listeners.delete(id);
  }
  // internal: subscribe with an auto id
  _subscribe(fn) {
    const id = `__rni${this._seq++}`;
    this._listeners.set(id, fn);
    return () => this._listeners.delete(id);
  }
  _cancel() {
    const a = this._anim;
    this._anim = null;
    if (a) a.finish(false);
  }
}

const makeMutable = (v) => new SharedValue(v);
const cancelAnimation = (sv) => sv && sv._cancel && sv._cancel();

function animation(spec, callback) {
  // defineProperties, not spread: withDelay forwards toValue through accessors.
  const a = {
    [ANIM]: true,
    current: undefined,
    finish(ok) {
      if (callback) callback(ok, this.current);
    },
  };
  return Object.defineProperties(a, Object.getOwnPropertyDescriptors(spec));
}

function withTiming(toValue, config, callback) {
  const duration = config && config.duration != null ? config.duration : 300;
  const ease = toEasing(config && config.easing, Easing.inOut(Easing.quad));
  return animation({
    toValue,
    start(from, t) {
      this.from = from;
      this.t0 = t;
      this.current = from;
    },
    frame(t) {
      const p = duration <= 0 ? 1 : Math.min(1, (t - this.t0) / duration);
      this.current = p >= 1 ? this.toValue : mix(this.from, this.toValue, ease(p));
      return p >= 1;
    },
  }, callback);
}

// Damped harmonic oscillator, Reanimated 3's defaults, integrated in 1 ms
// steps so the result does not depend on the frame rate.
function withSpring(toValue, config, callback) {
  const c = {mass: 1, stiffness: 100, damping: 10, velocity: 0, overshootClamping: false,
    restDisplacementThreshold: 0.01, restSpeedThreshold: 2, ...(config || {})};
  return animation({
    toValue,
    start(from, t) {
      this.x = typeof from === 'number' ? from : toValue;
      this.v = c.velocity;
      this.t = t;
      this.current = this.x;
    },
    frame(t) {
      const to = this.toValue;
      let steps = Math.min(Math.max(0, Math.round(t - this.t)), 1000);
      this.t = t;
      while (steps-- > 0) {
        const a = (-c.stiffness * (this.x - to) - c.damping * this.v) / c.mass;
        this.v += a * 0.001;
        this.x += this.v * 0.001;
      }
      const overshot = c.overshootClamping && (this.x - to) * (this.current - to) < 0;
      const rest = Math.abs(this.x - to) < c.restDisplacementThreshold && Math.abs(this.v) < c.restSpeedThreshold;
      this.current = overshot || rest ? to : this.x;
      return overshot || rest;
    },
  }, callback);
}

function withDecay(config, callback) {
  const c = {velocity: 0, deceleration: 0.998, ...(config || {})};
  return animation({
    start(from, t) {
      this.x = typeof from === 'number' ? from : 0;
      this.v = c.velocity;
      this.t = t;
      this.current = this.x;
    },
    frame(t) {
      const dt = Math.max(0, t - this.t);
      this.t = t;
      const k = Math.pow(c.deceleration, dt);
      this.x += (this.v / 1000) * ((1 - k) / (1 - c.deceleration));
      this.v *= k;
      let done = Math.abs(this.v) < 0.5;
      if (Array.isArray(c.clamp)) {
        const [lo, hi] = c.clamp;
        if (this.x <= lo || this.x >= hi) {
          this.x = Math.min(Math.max(this.x, lo), hi);
          done = true;
        }
      }
      this.current = this.x;
      return done;
    },
  }, callback);
}

const toAnim = (a) => (isAnimation(a) ? a : withTiming(a, {duration: 0}));

function withDelay(delayMs, inner) {
  const a = toAnim(inner);
  return animation({
    get toValue() {
      return a.toValue;
    },
    set toValue(v) {
      a.toValue = v;
    },
    start(from, t) {
      this.t0 = t;
      this.from = from;
      this.started = false;
      this.current = from;
    },
    frame(t) {
      if (t - this.t0 < delayMs) return false;
      if (!this.started) {
        this.started = true;
        a.start(this.from, this.t0 + delayMs);
      }
      const done = a.frame(t);
      this.current = a.current;
      if (done) a.finish(true);
      return done;
    },
  });
}

function withSequence(...inners) {
  const list = inners.map(toAnim);
  return animation({
    start(from, t) {
      this.i = 0;
      this.current = from;
      if (list.length) list[0].start(from, t);
    },
    frame(t) {
      while (this.i < list.length) {
        const a = list[this.i];
        const done = a.frame(t);
        this.current = a.current;
        if (!done) return false;
        a.finish(true);
        this.i++;
        if (this.i < list.length) list[this.i].start(this.current, t);
      }
      return true;
    },
  });
}

// numberOfReps <= 0 repeats forever; reverse swaps the inner animation's
// target with its start value on every other run.
function withRepeat(inner, numberOfReps = 2, reverse = false, callback) {
  const a = toAnim(inner);
  return animation({
    start(from, t) {
      this.n = 0;
      this.origin = from;
      this.target = a.toValue;
      this.current = from;
      a.start(from, t);
    },
    frame(t) {
      const done = a.frame(t);
      this.current = a.current;
      if (!done) return false;
      a.finish(true);
      this.n++;
      if (numberOfReps > 0 && this.n >= numberOfReps) return true;
      if (reverse && 'toValue' in a) a.toValue = this.n % 2 ? this.origin : this.target;
      a.start(reverse ? this.current : this.origin, t);
      return false;
    },
  }, callback);
}

module.exports = {
  SharedValue, makeMutable, isAnimation, track, cancelAnimation,
  withTiming, withSpring, withDecay, withDelay, withSequence, withRepeat,
};
