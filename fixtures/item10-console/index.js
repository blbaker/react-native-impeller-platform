/**
 * parity item 10 fixture: RN's console polyfill is installed.
 *
 * The engine used to replace `console` with a 4-method object, so
 * console.assert was undefined and `new AbortController().abort()` threw
 * "console.assert is not a function" (abort-controller calls it). Each check
 * logs one CONSOLE_* line the gate reads; a throw logs CONSOLE_THREW.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';

function check(name, fn) {
  try {
    const r = fn();
    console.log('CONSOLE_' + name + ' ok ' + (r === undefined ? '' : String(r)));
  } catch (e) {
    console.log('CONSOLE_THREW ' + name + ' ' + (e && e.message));
  }
}

check('ASSERT_TYPE', () => typeof console.assert);
check('ABORT', () => {
  const c = new AbortController();
  c.abort();
  return c.signal.aborted;
});
check('ASSERT_FALSE', () => console.assert(false, 'expected-assert-message'));
check('TABLE_TYPE', () => typeof console.table);
check('GROUP', () => {
  console.group('grp');
  console.log('inside-group');
  console.groupEnd();
  return 'done';
});
check('MULTI_ARG', () => {
  console.log('MULTI', 1, {a: 2});
  return 'done';
});
check('DEBUG_TYPE', () => typeof console.debug);

function Fixture() {
  return <View style={{width: 400, height: 300, backgroundColor: '#111111'}} />;
}

AppRegistry.registerComponent('Item10Console', () => Fixture);
