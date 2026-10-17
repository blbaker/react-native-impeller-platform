/**
 * ENG-04 gate fixture — storage that SURVIVES A RELAUNCH.
 *
 * ⛔ ONE PROCESS CANNOT TEST PERSISTENCE.
 *
 * A set-then-get inside a single run passes against an in-memory Map. It also
 * passes against a writeFile that silently no-ops if the read is served from
 * any cache. The only assertion that means "this persisted" is a SECOND
 * PROCESS reading what a FIRST process wrote, so this fixture is driven twice
 * with RNI_STORAGE_PHASE selecting the arm.
 *
 * Phase "write": store values, then Alert the outcome.
 * Phase "read":  read them back WITHOUT writing, then Alert what was found.
 *
 * The engine counts Alert.alert() as alerts_shown=N and prints the message, so
 * the result crosses back out of the process where a gate can read it. That
 * makes every assertion below a JS-boundary crossing by construction: a native
 * file written perfectly that JS cannot read produces the wrong alert text.
 */
import React from 'react';
import {Alert, AppRegistry, Text, View} from 'react-native';
import Storage from 'react-native-impeller-platform/src/storage';

// ⛔ NOT process.env. HERMES HAS NO OS ENVIRONMENT.
//
// `process.env.X` survives bundling (metro leaves the member expression in
// place) and then reads UNDEFINED at runtime, because Hermes is not node and
// the engine never populates a process object from the OS. The fixture
// silently fell back to the 'write' arm in BOTH runs, so the read phase
// re-wrote the values it was supposed to be reading back -- a persistence test
// that could never fail. Measured: read.log contained the write alert.
//
// Phase arrives over --initial-url instead, which is a REAL host-to-JS channel
// (LinkingManager.getInitialURL, engine/modules/PlatformModules.cpp:170) and
// is already proven by the P4 gate.
import {Linking} from 'react-native';

// Deliberately hostile keys. The native primitive's allowlist is
// [A-Za-z0-9._-] with no nesting, so EVERY key here would be rejected if the
// JS shim did not encode it. A test using only 'foo' would pass with the
// encoding removed entirely.
const CASES = [
  ['@myapp/user:profile', '{"id":42}'],
  ['plain', 'hello'],
  ['with space and /slash', 'v2'],
  ['unicode-\u00e9\u4e2d', 'accented'],
  ['empty-value', ''],
];

async function runWrite() {
  const results = [];
  for (const [key, value] of CASES) {
    await Storage.setItem(key, value);
    results.push(key);
  }
  // Round-trip the encoder directly, so an encoding defect is distinguishable
  // from a storage defect rather than both showing up as "value missing".
  const enc = Storage.encodeKey('@myapp/user:profile');
  const dec = Storage.decodeKey(enc);
  const encOk = dec === '@myapp/user:profile';

  const keys = await Storage.getAllKeys();
  // ⛔ THE PAYLOAD GOES IN THE TITLE. The engine's AlertManager records and
  // prints only `title` (engine/modules/PlatformModules.cpp:159); the message
  // body is dropped. A fixture that put its result in the message would show
  // `alert=write` with no data and read as a broken assertion rather than a
  // wrong instrument -- which is exactly how this was first written.
  Alert.alert(
    'write wrote=' + results.length + ' keys=' + keys.length + ' encode_ok=' + encOk,
  );
}

async function runRead() {
  let hits = 0;
  let mismatches = [];
  for (const [key, expected] of CASES) {
    const got = await Storage.getItem(key);
    if (got === expected) {
      hits++;
    } else {
      mismatches.push(key + ':' + JSON.stringify(got));
    }
  }
  // A removed key must read null, not '' — the distinction the native half
  // preserves on purpose. Asserted in the read phase so it is a cross-process
  // fact and not a same-run artefact.
  await Storage.removeItem('plain');
  const afterRemove = await Storage.getItem('plain');
  const removedIsNull = afterRemove === null;
  // 'empty-value' was stored as '' and must STILL read '' after another key
  // was removed. If the primitive collapsed empty to missing, this flips.
  const emptyStillEmpty = (await Storage.getItem('empty-value')) === '';

  Alert.alert(
    'read hits=' +
      hits +
      '/' +
      CASES.length +
      ' removed_is_null=' +
      removedIsNull +
      ' empty_preserved=' +
      emptyStillEmpty +
      (mismatches.length ? ' MISMATCH=' + mismatches.join(',') : ''),
  );
}

function Fixture() {
  const [phase, setPhase] = React.useState('...');
  React.useEffect(() => {
    (async () => {
      const url = (await Linking.getInitialURL()) || '';
      // rniphase://read  ->  'read'
      const p = url.replace(/^[a-z]+:\/\//, '').replace(/\/$/, '') || 'write';
      setPhase(p);
      const run = p === 'read' ? runRead : runWrite;
      return run();
    })().catch(e => {
      // A thrown error must still cross the boundary. Swallowing it here would
      // make a broken module look like a silent pass.
      Alert.alert('error ' + String(e && e.message ? e.message : e));
    });
  }, []);
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      <Text style={{color: '#ffffff', fontSize: 16}}>{'phase=' + phase}</Text>
    </View>
  );
}

AppRegistry.registerComponent('P9Storage', () => Fixture);
