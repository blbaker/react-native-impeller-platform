'use strict';
// ENG-04 shape B, the JS half. An AsyncStorage-shaped API composed on top of
// the engine's ONE file primitive.
//
// WHY THIS LIVES IN JS
// -------------------
// The engine vends AppStorage.readFile/writeFile/deleteFile/listFiles and
// nothing more. That is a deliberate boundary: persistence is not a renderer
// concern, and if the engine owned a key-value API instead, every later need
// (structured values, namespacing, encryption, migration) would be a new C++
// row against a surface frozen in a native release. Here it is a JS change.
//
// Same division as Alert.impeller.js: the engine owns the CAPABILITY, JS owns
// the SHAPE.
//
// ⛔ ASYNC ON PURPOSE, OVER A SYNCHRONOUS PRIMITIVE.
// The native calls are synchronous (small flat files, called from the JS
// thread). This wrapper is async anyway, because async is the shape every RN
// storage consumer expects and the one you cannot retrofit later without
// breaking every caller. If the native half ever moves to a thread pool, no
// consumer of this module changes.

const {TurboModuleRegistry} = require('react-native');

// ⚠️ get, NOT getEnforcing. An engine built before ENG-04 does not vend
// AppStorage, and a hard throw at import time would take the whole bundle down
// on a version mismatch rather than failing the one feature. The null check in
// mod() turns that into a rejected Promise from the call that needed it.
const Native = TurboModuleRegistry.get('AppStorage');

function mod() {
  if (Native == null) {
    throw new Error(
      'AppStorage native module is unavailable. The engine binary predates ' +
        'ENG-04 (run `rn-impeller --list-modules` to confirm) — storage calls ' +
        'cannot work until the engine is updated.',
    );
  }
  return Native;
}

// ⛔ KEY ENCODING IS NOT OPTIONAL AND IT IS NOT COSMETIC.
//
// The native side enforces a conservative allowlist ([A-Za-z0-9._-], one flat
// file per key, no nesting) because that is what keeps the container listable
// and the containment check simple. Real storage keys are not like that:
// '@myapp/user:profile' is an ordinary AsyncStorage key and would be REJECTED
// by the primitive.
//
// So keys are hex-encoded here. That is reversible, which listKeys() depends
// on, and it means no key can ever collide with another or escape the
// container -- a sanitising scheme (replace bad chars with '_') would silently
// map 'a/b' and 'a_b' onto ONE file, and the caller would never be told.
function encodeKey(key) {
  if (typeof key !== 'string') {
    throw new TypeError('storage key must be a string, got ' + typeof key);
  }
  let out = '';
  for (let i = 0; i < key.length; i++) {
    const code = key.charCodeAt(i);
    // Encode the whole BMP code unit, not a byte: charCodeAt can return > 255
    // for non-ASCII keys, and a 2-hex-digit assumption would truncate them
    // into collisions ('\u0141' and 'A' both -> '41').
    out += code.toString(16).padStart(4, '0');
  }
  return out + '.v1';
}

function decodeKey(name) {
  if (!name.endsWith('.v1')) return null;
  const body = name.slice(0, -3);
  if (body.length % 4 !== 0) return null;
  let out = '';
  for (let i = 0; i < body.length; i += 4) {
    const code = parseInt(body.slice(i, i + 4), 16);
    if (Number.isNaN(code)) return null;
    out += String.fromCharCode(code);
  }
  return out;
}

// A missing key resolves to null, never to ''. Those are different facts --
// "nothing stored" vs "an empty string was stored" -- and the native primitive
// preserves the distinction specifically so this layer can too. Collapsing
// them would make removeItem() indistinguishable from setItem(k, '').
async function getItem(key) {
  return mod().readFile(encodeKey(key));
}

async function setItem(key, value) {
  if (typeof value !== 'string') {
    throw new TypeError(
      'storage values must be strings (stringify first), got ' + typeof value,
    );
  }
  const ok = mod().writeFile(encodeKey(key), value);
  if (!ok) {
    // The primitive returns false for a rejected key, a full disk, or a failed
    // atomic rename. It does not distinguish them, and neither can this layer
    // honestly, so the error says what is known rather than guessing.
    throw new Error('storage write failed for key: ' + key);
  }
}

// Idempotent, matching the native half: removing an absent key is success, not
// an error, because that is the state the caller asked for.
async function removeItem(key) {
  const ok = mod().deleteFile(encodeKey(key));
  if (!ok) throw new Error('storage delete failed for key: ' + key);
}

// Enumeration comes from the DIRECTORY, not from an index file this module
// maintains. An index is a second source of truth that drifts the moment a
// write succeeds and the index update does not.
async function getAllKeys() {
  const names = mod().listFiles();
  const keys = [];
  for (const name of names) {
    const decoded = decodeKey(name);
    // Skip anything this module did not write. A foreign file in the container
    // is not an error and must not break enumeration for everything else.
    if (decoded !== null) keys.push(decoded);
  }
  return keys;
}

async function clear() {
  const keys = await getAllKeys();
  for (const key of keys) {
    await removeItem(key);
  }
}

async function multiGet(keys) {
  const out = [];
  for (const key of keys) {
    out.push([key, await getItem(key)]);
  }
  return out;
}

async function multiSet(pairs) {
  for (const [key, value] of pairs) {
    await setItem(key, value);
  }
}

module.exports = {
  getItem,
  setItem,
  removeItem,
  getAllKeys,
  clear,
  multiGet,
  multiSet,
  // Exported for the gate: it asserts on the encoding round trip directly
  // rather than inferring it from a get/set pair, so an encoding bug and a
  // storage bug cannot be confused for each other.
  encodeKey,
  decodeKey,
};
