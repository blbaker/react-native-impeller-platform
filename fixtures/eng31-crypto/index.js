// ENG-31 contract: globalThis.crypto.getRandomValues against the WebCrypto
// rules, on the OS CSPRNG. Run by tools/ci-crypto.sh arm A (prebuilt bundle,
// node-free). One line per check:
//   [js] CRYPTO_CONTRACT <name> PASS|FAIL <detail>
//   [js] CRYPTO_FIRST32 <hex>       first 32-byte draw (arm C compares 2 runs)
//   [js] CRYPTO_STATS ...           65536-byte draw: zeros, distinct, chi2
//   [js] CRYPTO_CONTRACT_DONE pass=N fail=M
// The screen is green when every check passed, red otherwise.
const React = require('react');
const { AppRegistry, View } = require('react-native');

let pass = 0;
let fail = 0;
function check(name, fn) {
  let ok = false;
  let detail = '';
  try {
    const r = fn();
    ok = r === true;
    detail = ok ? '' : String(r);
  } catch (e) {
    detail = 'THREW ' + ((e && e.name) || '') + ': ' + ((e && e.message) || e);
  }
  if (ok) pass++;
  else fail++;
  console.log('CRYPTO_CONTRACT ' + name + ' ' + (ok ? 'PASS' : 'FAIL') + (detail ? ' ' + detail.slice(0, 160) : ''));
}
const hex = (u8) => Array.from(u8, (b) => (b < 16 ? '0' : '') + b.toString(16)).join('');
const allZero = (u8) => u8.every((x) => x === 0);
const grv = (a) => globalThis.crypto.getRandomValues(a);
function throwsNamed(fn, name) {
  try {
    fn();
  } catch (e) {
    return e && e.name === name ? true : 'threw ' + (e && e.name) + ' not ' + name;
  }
  return 'did not throw (wanted ' + name + ')';
}
const bytes = (view) => new Uint8Array(view.buffer, view.byteOffset, view.byteLength);

check('bare-read', () => {
  let t;
  try {
    t = typeof crypto; // eslint-disable-line no-undef
  } catch (e) {
    return 'typeof crypto THREW';
  }
  return t === 'object' || 'typeof crypto = ' + t;
});
check('shape', () => {
  const c = globalThis.crypto;
  if (typeof c.getRandomValues !== 'function') return 'getRandomValues ' + typeof c.getRandomValues;
  if (c.getRandomValues.length !== 1) return 'length ' + c.getRandomValues.length;
  const tag = Object.prototype.toString.call(c);
  return tag === '[object Crypto]' || 'tag ' + tag;
});
const first = new Uint8Array(32);
check('returns-same-array', () => grv(first) === first);
console.log('CRYPTO_FIRST32 ' + hex(first));
check('u8-32-nonzero-differ', () => {
  const b = grv(new Uint8Array(32));
  if (allZero(first)) return 'first draw all zero';
  return hex(first) !== hex(b) || 'two draws equal';
});
check('quota-65536-full', () => {
  const a = grv(new Uint8Array(65536));
  const b = grv(new Uint8Array(65536));
  for (let off = 0; off < 65536; off += 4096) {
    if (allZero(a.subarray(off, off + 4096))) return 'chunk at ' + off + ' all zero';
  }
  const counts = new Array(256).fill(0);
  for (let i = 0; i < a.length; i++) counts[a[i]]++;
  const exp = 65536 / 256;
  let chi2 = 0;
  for (const n of counts) chi2 += ((n - exp) * (n - exp)) / exp;
  const distinct = counts.filter((n) => n > 0).length;
  let same = 0;
  for (let i = 0; i < a.length; i++) if (a[i] === b[i]) same++;
  console.log('CRYPTO_STATS bytes=65536 zeros=' + counts[0] + ' distinct=' + distinct +
    ' chi2=' + chi2.toFixed(1) + ' same_as_second_draw=' + same);
  if (distinct !== 256) return 'distinct ' + distinct;
  if (chi2 > 400) return 'chi2 ' + chi2.toFixed(1);
  return same < 600 || 'second draw matches at ' + same + ' of 65536';
});
check('quota-65537-throws', () => {
  const a = new Uint8Array(65537);
  const r = throwsNamed(() => grv(a), 'QuotaExceededError');
  return r === true ? allZero(a) || 'array written before throwing' : r;
});
check('quota-counts-bytes', () => {
  const ok = grv(new Uint32Array(16384)); // 65536 bytes
  if (allZero(bytes(ok).subarray(65536 - 64))) return 'Uint32Array(16384) tail not filled';
  return throwsNamed(() => grv(new Uint32Array(16385)), 'QuotaExceededError'); // 65540 bytes
});
check('offset-respected', () => {
  const buf = new ArrayBuffer(96);
  grv(new Uint8Array(buf, 32, 32));
  const all = new Uint8Array(buf);
  if (!allZero(all.subarray(0, 32))) return 'bytes before the view written';
  if (!allZero(all.subarray(64, 96))) return 'bytes after the view written';
  return !allZero(all.subarray(32, 64)) || 'view bytes not written';
});
check('integer-types', () => {
  const kinds = [Int8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array];
  if (typeof BigInt64Array === 'function') kinds.push(BigInt64Array, BigUint64Array);
  for (const K of kinds) {
    const v = new K(16);
    if (grv(v) !== v) return K.name + ' not returned';
    if (allZero(bytes(v))) return K.name + ' all zero';
  }
  console.log('CRYPTO_INTEGER_TYPES ' + kinds.map((k) => k.name).join(','));
  return true;
});
check('float-rejected', () => {
  for (const K of [Float32Array, Float64Array]) {
    const v = new K(4);
    const r = throwsNamed(() => grv(v), 'TypeMismatchError');
    if (r !== true) return K.name + ': ' + r;
    if (!allZero(bytes(v))) return K.name + ' written';
  }
  return true;
});
check('dataview-rejected', () => {
  const buf = new ArrayBuffer(16);
  const r = throwsNamed(() => grv(new DataView(buf)), 'TypeMismatchError');
  return r === true ? allZero(new Uint8Array(buf)) || 'DataView buffer written' : r;
});
check('non-view-rejected', () => {
  const cases = [undefined, null, 42, 'abc', [1, 2, 3], {}, new ArrayBuffer(8)];
  for (let i = 0; i < cases.length; i++) {
    const r = throwsNamed(() => grv(cases[i]), 'TypeError');
    if (r !== true) return 'case ' + i + ': ' + r;
  }
  return throwsNamed(() => globalThis.crypto.getRandomValues(), 'TypeError');
});
check('spoof-rejected', () => {
  const buf = new ArrayBuffer(16);
  const fake = Object.create(Uint8Array.prototype, {
    buffer: { value: buf }, byteOffset: { value: 0 }, byteLength: { value: 16 },
    length: { value: 16 }, [Symbol.toStringTag]: { value: 'Uint8Array' },
  });
  const r = throwsNamed(() => grv(fake), 'TypeError');
  return r === true ? allZero(new Uint8Array(buf)) || 'fake view buffer written' : r;
});
check('intrinsics-captured', () => {
  const TA = Object.getPrototypeOf(Uint8Array.prototype);
  const saved = Object.getOwnPropertyDescriptor(TA, 'byteLength');
  const v = new Uint8Array(64);
  try {
    Object.defineProperty(TA, 'byteLength', { get() { return 1; }, configurable: true });
    grv(v);
  } finally {
    Object.defineProperty(TA, 'byteLength', saved);
  }
  return !allZero(v.subarray(32)) || 'patched byteLength getter steered the fill';
});
check('zero-length', () => {
  const v = new Uint8Array(0);
  return grv(v) === v;
});

console.log('CRYPTO_CONTRACT_DONE pass=' + pass + ' fail=' + fail);

function Contract() {
  return React.createElement(View, {
    style: { flex: 1, backgroundColor: fail === 0 && pass > 0 ? 'rgb(0, 255, 0)' : 'rgb(255, 0, 0)' },
  });
}
AppRegistry.registerComponent('CryptoContract', () => Contract);
