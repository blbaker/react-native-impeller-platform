// expo/fetch + ExponentConstants checks (SC-44), shared by contract.js
// (release, ci-expo-host) and dev/App.js (expo start, ci-expo-dev).
// `base` is the gate's python server (tools/expo_host_check.py serve).
// Every request starts at once: the headless host waits for in-flight native
// requests, so a chain of requests could be cut off after its first hop.
import {fetch as expoFetch} from 'expo/fetch';
import {requireOptionalNativeModule} from 'expo';

export const FETCH_CHECKS = [
  'constants', 'fetch-hello', 'fetch-status', 'fetch-post', 'fetch-redirect-follow',
  'fetch-redirect-manual', 'fetch-redirect-error', 'fetch-abort', 'fetch-stream', 'fetch-global',
];

function settle(p) {
  return p.then((v) => ({ok: true, v}), (e) => ({ok: false, e}));
}

export function checkConstants(check) {
  const c = requireOptionalNativeModule('ExponentConstants');
  const m = c && c.manifest;
  check(
    'constants',
    !!c &&
      c.executionEnvironment === 'bare' &&
      c.appOwnership == null &&
      !!m && m.name === 'probe' && m.slug === 'probe' &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(c.sessionId) &&
      c.statusBarHeight === 0 &&
      Array.isArray(c.systemFonts) &&
      typeof c.platform === 'object',
    c ? 'env=' + c.executionEnvironment + ' manifest=' + JSON.stringify(m) : 'absent',
  );
}

// The NativeResponse streaming contract FetchResponse.body is built on:
// startStreaming() resolves null, then didReceiveResponseData chunks and
// didComplete. Driven directly because this runtime has no global
// ReadableStream (response.body throws "Property 'ReadableStream' doesn't exist").
function readStream(res) {
  return new Promise((resolve, reject) => {
    let chunks = 0;
    let total = 0;
    let bad = 0;
    res.addListener('didReceiveResponseData', (value) => {
      for (let i = 0; i < value.length; i++) if (value[i] !== ((total + i) * 7) % 256) bad++;
      chunks++;
      total += value.length;
    });
    res.addListener('didFailWithError', (e) => reject(new Error(e)));
    res.addListener('didComplete', () => resolve({chunks, total, bad, first}));
    let first = 'pending';
    res.startStreaming().then((v) => (first = v === null ? 'null' : 'data'), reject);
  });
}

export function runFetchChecks(base, check) {
  const t0 = Date.now();
  const ac = new AbortController();
  const cases = {
    hello: settle(
      expoFetch(base + '/fetch/hello', {headers: {'X-Rni-Req': 'sc44'}}).then(async (r) => ({
        status: r.status, ok: r.ok, probe: r.headers.get('x-rni-probe'),
        echo: r.headers.get('x-rni-echo'), text: await r.text(),
      })),
    ),
    teapot: settle(
      expoFetch(base + '/fetch/teapot').then(async (r) => ({
        status: r.status, statusText: r.statusText, ok: r.ok, text: await r.text(),
      })),
    ),
    post: settle(
      expoFetch(base + '/fetch/echo', {method: 'POST', body: 'ping-body'}).then((r) => r.text()),
    ),
    follow: settle(expoFetch(base + '/fetch/redirect')),
    manual: settle(expoFetch(base + '/fetch/redirect', {redirect: 'manual'})),
    error: settle(expoFetch(base + '/fetch/redirect', {redirect: 'error'})),
    abort: settle(expoFetch(base + '/fetch/slow', {signal: ac.signal})).then((r) => ({
      ...r, ms: Date.now() - t0,
    })),
    stream: settle(expoFetch(base + '/fetch/big').then(readStream)),
    global: settle(
      globalThis.fetch(base + '/fetch/hello').then(async (r) => ({
        expo: typeof r.startStreaming === 'function', text: await r.text(),
      })),
    ),
  };
  setTimeout(() => ac.abort(), 150);
  const names = Object.keys(cases);
  return Promise.all(names.map((n) => cases[n])).then((results) => {
    const r = {};
    names.forEach((n, i) => (r[n] = results[i]));
    const s = (x) => (x.ok ? JSON.stringify(x.v) : 'threw ' + (x.e && x.e.message));
    const h = r.hello.v || {};
    check(
      'fetch-hello',
      r.hello.ok && h.status === 200 && h.ok === true && h.probe === 'sc44-probe' &&
        h.echo === 'sc44' && h.text === 'hello from sc44 ✓',
      s(r.hello),
    );
    const t = r.teapot.v || {};
    check(
      'fetch-status',
      r.teapot.ok && t.status === 418 && t.statusText === "I'm a teapot" && t.ok === false &&
        t.text === 'teapot',
      s(r.teapot),
    );
    check('fetch-post', r.post.ok && r.post.v === 'POST:ping-body', s(r.post));
    const f = r.follow.v;
    check(
      'fetch-redirect-follow',
      r.follow.ok && f.status === 200 && f.redirected === true && /\/fetch\/hello$/.test(f.url),
      r.follow.ok ? f.status + ' redirected=' + f.redirected + ' ' + f.url : s(r.follow),
    );
    check(
      'fetch-redirect-manual',
      r.manual.ok && r.manual.v.status === 302 && r.manual.v.redirected === false,
      r.manual.ok ? String(r.manual.v.status) : s(r.manual),
    );
    check('fetch-redirect-error', !r.error.ok, r.error.ok ? 'resolved' : String(r.error.e.message));
    check(
      'fetch-abort',
      !r.abort.ok && r.abort.ms < 2000,
      (r.abort.ok ? 'resolved' : 'rejected ' + (r.abort.e && r.abort.e.name)) + ' after ' + r.abort.ms + 'ms',
    );
    const st = r.stream.v || {};
    check(
      'fetch-stream',
      r.stream.ok && st.total === 200000 && st.bad === 0 && st.chunks >= 3 && st.first === 'null',
      s(r.stream),
    );
    check('fetch-global', r.global.ok && r.global.v.expo && r.global.v.text === 'hello from sc44 ✓', s(r.global));
  });
}
