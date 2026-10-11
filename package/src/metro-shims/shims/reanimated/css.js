'use strict';
// SC-26. CSS animations and transitions as react-native-css hands them to an
// Animated component (Reanimated 4's style props): animationName is a
// keyframes object {'from'|'to'|'0.5'|'75%, to': style}, durations and delays
// are ms, lists cycle per CSS. Evaluated on every render of the component at
// clock.now(); `active` says whether another frame is needed.
const {mix} = require('./interpolate');
const {toEasing} = require('./easing');

const CSS_KEYS = ['animationName', 'animationDuration', 'animationDelay', 'animationIterationCount',
  'animationDirection', 'animationFillMode', 'animationPlayState', 'animationTimingFunction',
  'transitionProperty', 'transitionDuration', 'transitionDelay', 'transitionTimingFunction',
  'transitionBehavior'];

const list = (v) => (v === undefined ? [] : Array.isArray(v) ? v : [v]);
const nth = (v, i, d) => {
  const l = list(v);
  return l.length ? l[i % l.length] : d;
};
const same = (a, b) => a === b || JSON.stringify(a) === JSON.stringify(b);

// Split a flattened style into the paintable style and the CSS motion props.
function split(style) {
  const base = {};
  const css = {};
  let any = false;
  for (const k of Object.keys(style || {})) {
    if (CSS_KEYS.includes(k)) {
      css[k] = style[k];
      any = true;
    } else {
      base[k] = style[k];
    }
  }
  return {base, css: any ? css : null};
}

function offsets(key) {
  return String(key).split(',').map((s) => {
    const t = s.trim();
    if (t === 'from') return 0;
    if (t === 'to') return 1;
    return t.endsWith('%') ? parseFloat(t) / 100 : parseFloat(t);
  }).filter((n) => n >= 0 && n <= 1);
}

// keyframes object -> {prop: [{o, v, ease}]} sorted by offset.
function compile(frames) {
  const tracks = {};
  for (const key of Object.keys(frames || {})) {
    const decl = frames[key] || {};
    const ease = decl.animationTimingFunction;
    for (const o of offsets(key)) {
      for (const p of Object.keys(decl)) {
        if (p === 'animationTimingFunction') continue;
        (tracks[p] = tracks[p] || []).push({o, v: decl[p], ease});
      }
    }
  }
  for (const p of Object.keys(tracks)) tracks[p].sort((a, b) => a.o - b.o);
  return tracks;
}

function neutral(prop, base) {
  if (base[prop] !== undefined) return base[prop];
  if (prop === 'opacity') return 1;
  if (prop === 'transform') return [];
  if (/color$/i.test(prop)) return 'transparent';
  return 0;
}

function sample(track, prop, base, p, ease) {
  const pts = track.slice();
  if (pts[0].o > 0) pts.unshift({o: 0, v: neutral(prop, base)});
  if (pts[pts.length - 1].o < 1) pts.push({o: 1, v: neutral(prop, base)});
  let i = 0;
  while (i < pts.length - 2 && p > pts[i + 1].o) i++;
  const a = pts[i];
  const b = pts[i + 1];
  const span = b.o - a.o;
  const local = span <= 0 ? 1 : Math.min(1, Math.max(0, (p - a.o) / span));
  const e = a.ease !== undefined ? toEasing(a.ease) : ease;
  return mix(a.v, b.v, e(local));
}

// Iteration progress of animation i at time t, or null when it has no effect.
function progress(st, css, i, t) {
  const duration = nth(css.animationDuration, i, 0);
  const delay = nth(css.animationDelay, i, 0);
  const countRaw = nth(css.animationIterationCount, i, 1);
  const count = countRaw === 'infinite' ? Infinity : Number(countRaw);
  const dir = nth(css.animationDirection, i, 'normal');
  const fill = nth(css.animationFillMode, i, 'none');
  const active = ((st.pausedAt != null ? st.pausedAt : t) - st.origin) - delay;
  const flip = (n, f) => {
    const rev = dir === 'reverse' || (dir === 'alternate' && n % 2 === 1) || (dir === 'alternate-reverse' && n % 2 === 0);
    return rev ? 1 - f : f;
  };
  if (active < 0) {
    return {p: fill === 'backwards' || fill === 'both' ? flip(0, 0) : null, running: st.pausedAt == null};
  }
  const total = duration * count;
  if (duration <= 0 || active >= total) {
    if (fill !== 'forwards' && fill !== 'both') return {p: null, running: false};
    const n = Math.max(0, Math.ceil(count) - 1);
    const end = count % 1 === 0 || !isFinite(count) ? 1 : count % 1;
    return {p: flip(n, end), running: false};
  }
  const n = Math.floor(active / duration);
  return {p: flip(n, (active - n * duration) / duration), running: st.pausedAt == null};
}

function animations(state, base, css, out, t) {
  const names = list(css.animationName);
  const next = [];
  let running = false;
  names.forEach((frames, i) => {
    if (!frames || typeof frames !== 'object') return;
    const key = JSON.stringify(frames) + '|' + nth(css.animationDuration, i, 0);
    let st = state.anims.find((s) => s.key === key && !next.includes(s));
    if (!st) st = {key, tracks: compile(frames), origin: t, pausedAt: null};
    const paused = nth(css.animationPlayState, i, 'running') === 'paused';
    if (paused && st.pausedAt == null) st.pausedAt = t;
    if (!paused && st.pausedAt != null) {
      st.origin += t - st.pausedAt;
      st.pausedAt = null;
    }
    next.push(st);
    const r = progress(st, css, i, t);
    running = running || r.running;
    if (r.p == null) return;
    const ease = toEasing(nth(css.animationTimingFunction, i, 'ease'));
    for (const prop of Object.keys(st.tracks)) out[prop] = sample(st.tracks[prop], prop, base, r.p, ease);
  });
  state.anims = next;
  return running;
}

function transitions(state, base, css, out, t) {
  const props = list(css && css.transitionProperty);
  const covered = (p) => {
    const i = props.indexOf(p);
    if (i >= 0) return i;
    const all = props.indexOf('all');
    return all >= 0 ? all : -1;
  };
  let running = false;
  const keys = new Set([...Object.keys(base), ...Object.keys(state.last || {})]);
  for (const p of keys) {
    const target = base[p];
    const prev = state.last ? state.last[p] : undefined;
    const i = props.length ? covered(p) : -1;
    if (state.last && i >= 0 && !same(prev, target)) {
      const duration = nth(css.transitionDuration, i, 0);
      const delay = nth(css.transitionDelay, i, 0);
      if (duration > 0) {
        const from = state.shown[p] !== undefined ? state.shown[p] : prev !== undefined ? prev : neutral(p, {});
        state.tx[p] = {from, to: target, start: t + delay, duration, ease: toEasing(nth(css.transitionTimingFunction, i, 'ease'))};
      } else {
        delete state.tx[p];
      }
    } else if (i < 0) {
      delete state.tx[p];
    }
    const tx = state.tx[p];
    if (!tx) continue;
    const f = (t - tx.start) / tx.duration;
    if (f >= 1) {
      delete state.tx[p];
      continue;
    }
    running = true;
    const to = tx.to !== undefined ? tx.to : neutral(p, {});
    out[p] = f <= 0 ? tx.from : mix(tx.from, to, tx.ease(f));
  }
  state.last = base;
  return running;
}

function newState() {
  return {anims: [], tx: {}, last: null, shown: {}};
}

// The style to paint now, and whether the next frame differs.
function evaluate(state, base, css, t) {
  const out = {...base};
  const runT = transitions(state, base, css || {}, out, t);
  const runA = css ? animations(state, base, css, out, t) : (state.anims = [], false);
  state.shown = out;
  return {style: out, active: runT || runA};
}

module.exports = {split, evaluate, newState};
