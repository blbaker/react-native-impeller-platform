'use strict';
// SC-26. Value mixing for the reanimated stub: numbers, unit strings
// ('360deg', '-25%'), colours and transform lists, plus Reanimated's public
// interpolate / interpolateColor.
const {processColor} = require('react-native');

const UNIT = /^(-?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?)([a-z%]*)$/i;

function parseUnit(v) {
  const m = typeof v === 'string' ? UNIT.exec(v.trim()) : null;
  return m ? {n: parseFloat(m[1]), u: m[2]} : null;
}

// RN's processColor gives 0xAARRGGBB off android; anything else is not a colour.
function parseColor(v) {
  if (typeof v !== 'string' || parseUnit(v)) return null;
  const c = processColor(v);
  if (typeof c !== 'number') return null;
  return [(c >>> 16) & 255, (c >>> 8) & 255, c & 255, ((c >>> 24) & 255) / 255];
}

function mixColor(a, b, t) {
  const ch = (i) => Math.round(a[i] + (b[i] - a[i]) * t);
  const al = Math.round((a[3] + (b[3] - a[3]) * t) * 1000) / 1000;
  return `rgba(${ch(0)}, ${ch(1)}, ${ch(2)}, ${al})`;
}

function identityFor(key, like) {
  if (key.startsWith('scale')) return 1;
  if (key === 'perspective') return like;
  const u = parseUnit(like);
  if (u) return u.u ? `0${u.u}` : 0;
  return 0;
}

const keyOf = (o) => Object.keys(o)[0];

// CSS transform-list interpolation: pair by position when the function
// names line up, padding the shorter list with identities; otherwise the
// union of both lists, each side missing a function at its identity.
function mixTransform(a, b, t) {
  const A = Array.isArray(a) ? a : [];
  const B = Array.isArray(b) ? b : [];
  const n = Math.min(A.length, B.length);
  let aligned = true;
  for (let i = 0; i < n; i++) if (keyOf(A[i]) !== keyOf(B[i])) aligned = false;
  let keys;
  const pick = (L, k, i) => {
    if (aligned) return L[i] ? L[i][k] : undefined;
    const e = L.find((o) => keyOf(o) === k);
    return e ? e[k] : undefined;
  };
  if (aligned) {
    keys = (A.length >= B.length ? A : B).map(keyOf);
  } else {
    keys = A.map(keyOf);
    for (const o of B) if (!keys.includes(keyOf(o))) keys.push(keyOf(o));
  }
  return keys.map((k, i) => {
    let va = pick(A, k, i);
    let vb = pick(B, k, i);
    if (va === undefined) va = identityFor(k, vb);
    if (vb === undefined) vb = identityFor(k, va);
    return {[k]: mix(va, vb, t)};
  });
}

// mix(a, b, t): the value t of the way from a to b. Values that cannot be
// interpolated switch at the midpoint, as CSS discrete animation does.
function mix(a, b, t) {
  if (typeof a === 'number' && typeof b === 'number') return a + (b - a) * t;
  if (Array.isArray(a) || Array.isArray(b)) {
    const isT = (L) => Array.isArray(L) && L.every((o) => o && typeof o === 'object' && Object.keys(o).length === 1);
    if ((a == null || isT(a)) && (b == null || isT(b))) return mixTransform(a, b, t);
  }
  const ua = typeof a === 'number' ? {n: a, u: ''} : parseUnit(a);
  const ub = typeof b === 'number' ? {n: b, u: ''} : parseUnit(b);
  if (ua && ub && (ua.u === ub.u || !ua.n || !ub.n)) {
    const u = ua.u || ub.u;
    const n = ua.n + (ub.n - ua.n) * t;
    return u ? `${n}${u}` : n;
  }
  const ca = parseColor(a);
  const cb = parseColor(b);
  if (ca && cb) return mixColor(ca, cb, t);
  return t < 0.5 ? a : b;
}

function segment(x, input) {
  let i = 1;
  while (i < input.length - 1 && x > input[i]) i++;
  return i - 1;
}

function extrapolate(x, edge, mode) {
  if (mode === 'identity') return {value: x};
  if (mode === 'clamp') return {value: edge};
  return null;
}

// Reanimated's interpolate(x, input, output, extrapolation).
function interpolate(x, input, output, type) {
  if (!Array.isArray(input) || !Array.isArray(output) || input.length < 2) return x;
  const cfg = typeof type === 'object' && type ? type : {extrapolateLeft: type, extrapolateRight: type};
  const left = cfg.extrapolateLeft || 'extend';
  const right = cfg.extrapolateRight || 'extend';
  const last = input.length - 1;
  if (x < input[0]) {
    const e = extrapolate(x, output[0], left);
    if (e) return e.value;
  } else if (x > input[last]) {
    const e = extrapolate(x, output[last], right);
    if (e) return e.value;
  }
  const i = segment(x, input);
  const span = input[i + 1] - input[i];
  const t = span === 0 ? 0 : (x - input[i]) / span;
  return output[i] + (output[i + 1] - output[i]) * t;
}

// Reanimated's interpolateColor(x, input, colours): RGB space, clamped.
function interpolateColor(x, input, output) {
  const cols = output.map(parseColor);
  if (cols.some((c) => !c)) return output[0];
  if (x <= input[0]) return mixColor(cols[0], cols[0], 0);
  const last = input.length - 1;
  if (x >= input[last]) return mixColor(cols[last], cols[last], 0);
  const i = segment(x, input);
  const span = input[i + 1] - input[i];
  return mixColor(cols[i], cols[i + 1], span === 0 ? 0 : (x - input[i]) / span);
}

module.exports = {mix, interpolate, interpolateColor};
