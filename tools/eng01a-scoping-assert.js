'use strict';
// ENG-01a scoping contract. Asserts what a pixel probe CANNOT see: a bundle
// that swapped Platform GLOBALLY renders an identical screenshot to one that
// swapped it for TextInput.js alone. Only the second is correct. The first
// silently unpicks every shim, every .impeller.js extension, and every app-level
// `Platform.OS === 'impeller'` branch -- with all pixel gates still green.
//
// Resolves the resolver relative to THIS file, so it works in a mutation copy.
const assert = require('assert');
const path = require('path');

const R = path.join(__dirname, '..', 'package', 'src', 'metro-shims');
const s = require(R);

const RN = '/x/node_modules/react-native/';
const PLATFORM = RN + 'Libraries/Utilities/Platform.js';
const TEXTINPUT = RN + 'Libraries/Components/TextInput/TextInput.js';
const VIEW = RN + 'Libraries/Components/View/View.js';

let n = 0;
const check = (label, fn) => {
  try {
    fn();
  } catch (e) {
    console.log(`  BAD ${label}`);
    console.log(`ENG01A_SCOPING_FAIL: ${label} -- ${e.message.split('\n')[0]}`);
    process.exit(1);
  }
  console.log(`  ok  ${++n} ${label}`);
};

check('TextInput.js asking for Platform gets the forged shim', () => {
  const got = s.shimForOrigin(TEXTINPUT, PLATFORM);
  assert.ok(got && got.endsWith('Platform.impeller-as-ios.js'), String(got));
});

// ⛔ THE LOAD-BEARING ONE. Everything else can regress loudly; this regresses silently.
check('View.js asking for Platform is NOT redirected', () => {
  assert.strictEqual(s.shimForOrigin(VIEW, PLATFORM), null);
});

check('TextInput.js asking for a non-Platform module is NOT redirected', () => {
  assert.strictEqual(s.shimForOrigin(TEXTINPUT, RN + 'Libraries/Text/Text.js'), null);
});

const forged = require(path.join(R, 'shims', 'Platform.impeller-as-ios.js'));
const real = require(path.join(R, 'shims', 'Platform.impeller.js'));

check('forged reports ios, the global shim still reports impeller', () => {
  assert.strictEqual(forged.OS, 'ios');
  assert.strictEqual(real.OS, 'impeller');
});

// An app that wrote select({impeller: x, ios: y}) means x. The lie is the OS
// string only; it must not propagate into select().
check('select() still resolves impeller first', () => {
  assert.strictEqual(forged.select({impeller: 'IMP', ios: 'IOS'}), 'IMP');
});

check('packaging marker inherited, so pack-and-consume still greps clean', () => {
  assert.strictEqual(forged.__marker, real.RN_IMPELLER_SHIM_MARKER);
});

console.log(`ENG01A_SCOPING_PASS (${n} assertions)`);
