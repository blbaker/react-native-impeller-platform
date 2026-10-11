// expo-host contract fixture (tools/ci-expo-host.sh arm B).
//
// Exercises globalThis.expo through Expo's OWN JS (expo / expo-modules-core),
// not by poking the global directly, so a host that satisfies the typed
// contract but breaks the way Expo calls it still fails. Every check prints
// one line:   EXPO_CONTRACT <name> <PASS|FAIL> <detail>
// and the run ends with EXPO_CONTRACT_DONE pass=<n> fail=<m>.
//
// The gate passes its local HTTP server and the MD5s it computed with Python
// through the initial URL:
//   rniexpo://contract?base=http://127.0.0.1:PORT&md5B=..&md5C=..&md5D=..&md5E=..
import React, {useEffect, useState} from 'react';
import {Linking, Text, View} from 'react-native';
import {
  registerRootComponent,
  requireNativeModule,
  requireOptionalNativeModule,
  isRunningInExpoGo,
  EventEmitter,
  NativeModule,
  SharedObject,
  SharedRef,
} from 'expo';
import {uuid, CodedError} from 'expo-modules-core';

let pass = 0;
let fail = 0;
function check(name, ok, detail) {
  if (ok) pass++;
  else fail++;
  console.log('EXPO_CONTRACT ' + name + ' ' + (ok ? 'PASS' : 'FAIL') + ' ' + (detail || ''));
}
function guard(name, fn) {
  try {
    fn();
  } catch (e) {
    check(name, false, 'threw ' + (e && e.message));
  }
}

// --- synchronous checks -----------------------------------------------------
guard('classes', () => {
  const m = new NativeModule();
  const r = new SharedRef();
  check(
    'classes',
    typeof EventEmitter === 'function' &&
      m instanceof EventEmitter &&
      r instanceof SharedObject &&
      r instanceof EventEmitter &&
      r.nativeRefType === 'unknown' &&
      typeof r.release === 'function',
    'nativeRefType=' + r.nativeRefType,
  );
});

guard('emitter', () => {
  const log = [];
  class Probe extends EventEmitter {
    startObserving(e) {
      log.push('start:' + e);
    }
    stopObserving(e) {
      log.push('stop:' + e);
    }
  }
  const p = new Probe();
  const got = [];
  const s1 = p.addListener('tick', (a, b) => got.push('l1:' + a + ',' + b));
  p.addListener('tick', () => {
    throw new Error('listener throws on purpose');
  });
  p.addListener('tick', (a) => got.push('l3:' + a));
  const countAfterAdd = p.listenerCount('tick');
  // A throwing listener is reported through console.error and does not stop
  // the others (expo-modules-core semantics). Record it here instead of
  // letting it reach the redbox, so the gate's zero-[js-error] rule stays strict.
  const reported = [];
  const realError = console.error;
  console.error = (e) => reported.push(String(e && e.message));
  try {
    p.emit('tick', 1, 2);
    s1.remove();
    p.emit('tick', 3);
  } finally {
    console.error = realError;
  }
  const countAfterRemove = p.listenerCount('tick');
  p.removeAllListeners('tick');
  const detail =
    'got=' + got.join('|') + ' log=' + log.join('|') + ' counts=' + countAfterAdd + ',' +
    countAfterRemove + ',' + p.listenerCount('tick') + ' reported=' + reported.length;
  check(
    'emitter',
    got.join('|') === 'l1:1,2|l3:1|l3:3' &&
      reported.length === 2 &&
      reported[0] === 'listener throws on purpose' &&
      log.join('|') === 'start:tick|stop:tick' &&
      countAfterAdd === 3 &&
      countAfterRemove === 2 &&
      p.listenerCount('tick') === 0,
    detail,
  );
});

guard('subclass', () => {
  class Mine extends NativeModule {
    hello() {
      return 'hi';
    }
  }
  const m = new Mine();
  check('subclass', m.hello() === 'hi' && m instanceof NativeModule && m instanceof EventEmitter, '');
});

guard('uuidv4', () => {
  const a = uuid.v4();
  const b = uuid.v4();
  const re = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  check('uuidv4', re.test(a) && re.test(b) && a !== b, a);
});

guard('uuidv5', () => {
  // Gate compares the value to Python's uuid.uuid5(NAMESPACE_DNS, ...).
  const v = uuid.v5('www.example.com', '6ba7b810-9dad-11d1-80b4-00c04fd430c8');
  console.log('EXPO_UUIDV5 ' + v);
  check('uuidv5-shape', /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v), v);
  let threw = false;
  try {
    globalThis.expo.uuidv5('x', 'not-a-uuid');
  } catch (e) {
    threw = true;
  }
  check('uuidv5-bad-namespace-throws', threw, '');
});

guard('modules', () => {
  const asset = requireNativeModule('ExpoAsset');
  const again = requireNativeModule('ExpoAsset');
  const keys = Object.keys(globalThis.expo.modules);
  check(
    'modules',
    asset === again &&
      asset instanceof NativeModule &&
      typeof asset.downloadAsync === 'function' &&
      keys.indexOf('ExpoAsset') >= 0,
    'keys=' + keys.join(','),
  );
  check(
    'expo-go-absent',
    requireOptionalNativeModule('ExpoGo') === null && isRunningInExpoGo() === false,
    '',
  );
});

guard('globals', () => {
  const e = globalThis.expo;
  let uiThrew = false;
  try {
    e.installOnUIRuntime({});
  } catch (err) {
    uiThrew = true;
  }
  check(
    'globals',
    e.getViewConfig('Nope') === null &&
      uiThrew &&
      typeof e.reloadAppAsync === 'function' &&
      typeof e.cacheDir === 'string' &&
      typeof e.documentsDir === 'string',
    'cacheDir=' + e.cacheDir + ' documentsDir=' + e.documentsDir,
  );
  console.log('EXPO_DIRS cacheDir=' + e.cacheDir + ' documentsDir=' + e.documentsDir);
});

// --- asynchronous: ExpoAsset.downloadAsync ---------------------------------
// All cases start together: the headless host waits for in-flight native
// requests once, so a sequential chain would be cut off after its first hop.
function settle(p) {
  return p.then(
    (v) => ({ok: true, v}),
    (e) => ({ok: false, e}),
  );
}

function runDownloads(url) {
  const q = {};
  (url.split('?')[1] || '').split('&').forEach((kv) => {
    const i = kv.indexOf('=');
    if (i > 0) q[kv.slice(0, i)] = decodeURIComponent(kv.slice(i + 1));
  });
  const base = q.base;
  const asset = requireNativeModule('ExpoAsset');
  const cases = {
    a: settle(asset.downloadAsync(base + '/a.bin', null, 'bin')),
    b: settle(asset.downloadAsync(base + '/b.bin', q.md5B, 'bin')),
    c: settle(asset.downloadAsync(base + '/missing-c.bin', q.md5C, 'bin')),
    d: settle(asset.downloadAsync(base + '/missing-d.bin', q.md5D, 'bin')),
    e: settle(asset.downloadAsync(base + '/e.bin', q.md5E, 'bin')),
    f: settle(asset.downloadAsync('file:///opt/app/assets/icon.png', null, 'png')),
    // type is JS-supplied and becomes part of a file name: '/' must not let
    // it walk out of the cache dir (b.bin is served, so only the name check
    // stands between this and <cache>/../escape).
    g: settle(asset.downloadAsync(base + '/b.bin', null, 'bin/../../escape')),
  };
  const names = Object.keys(cases);
  return Promise.all(names.map((n) => cases[n])).then((results) => {
    const r = {};
    names.forEach((n, i) => (r[n] = results[i]));
    // Gate checks the file each one names on disk.
    names.forEach((n) =>
      console.log('EXPO_DL ' + n + ' ' + (r[n].ok ? 'ok ' + r[n].v : 'err ' + (r[n].e && r[n].e.code))),
    );
    check('dl-a-no-md5', r.a.ok && /\/ExponentAsset-[0-9a-f]{32}\.bin$/.test(r.a.v), String(r.a.v));
    check('dl-b-md5', r.b.ok && r.b.v.endsWith('/ExponentAsset-' + q.md5B + '.bin'), String(r.b.v));
    check('dl-c-cache-hit', r.c.ok && r.c.v.endsWith('/ExponentAsset-' + q.md5C + '.bin'), String(r.c.v));
    check(
      'dl-d-rejects-coded',
      !r.d.ok && r.d.e instanceof CodedError && r.d.e.code === 'ERR_UNABLE_TO_DOWNLOAD_ASSET',
      String(r.d.e && r.d.e.code),
    );
    check('dl-e-stale-refetch', r.e.ok && r.e.v.endsWith('/ExponentAsset-' + q.md5E + '.bin'), String(r.e.v));
    check('dl-f-file-passthrough', r.f.ok && r.f.v === 'file:///opt/app/assets/icon.png', String(r.f.v));
    check('dl-g-rejects-escape', !r.g.ok, String(r.g.e && r.g.e.code));
  });
}

let notify = null;
Linking.getInitialURL()
  .then((url) => {
    if (!url) {
      check('initial-url', false, 'no --initial-url');
      return null;
    }
    return runDownloads(url);
  })
  .catch((e) => check('downloads', false, 'threw ' + (e && e.message)))
  .then(() => {
    console.log('EXPO_CONTRACT_DONE pass=' + pass + ' fail=' + fail);
    if (notify) notify();
  });

function Contract() {
  const [, setTick] = useState(0);
  useEffect(() => {
    notify = () => setTick((t) => t + 1);
  }, []);
  const color = fail === 0 && pass > 0 ? '#1f8a3a' : '#a01818';
  return (
    <View style={{flex: 1, backgroundColor: color, alignItems: 'center', justifyContent: 'center'}}>
      <Text style={{color: '#ffffff', fontSize: 24}}>{'expo contract ' + pass + '/' + (pass + fail)}</Text>
    </View>
  );
}

registerRootComponent(Contract);
