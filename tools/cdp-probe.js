#!/usr/bin/env node
// CDP probe for tools/ci-debugger.sh (parity item 24).
// usage: cdp-probe.js <metro-origin> <app-name> <out.json>
// Finds the app's page in Metro's /json/list, opens its webSocketDebuggerUrl
// (as React Native DevTools does) and runs a fixed script of CDP calls.
// Prints one `CDP <step> <json>` line per result; exits 0 when the script ran.
const http = require('http');
const WebSocket = require('ws');

const [origin, appName, mode] = process.argv.slice(2);
// mode 'hold': attach (Runtime + Debugger enabled), then stay attached until
// the APP quits -- the "closed the app with DevTools open" case.

function getJson(url) {
  return new Promise((resolve, reject) => {
    http
      .get(url, res => {
        let body = '';
        res.on('data', c => (body += c));
        res.on('end', () => {
          try {
            resolve(JSON.parse(body));
          } catch (e) {
            reject(new Error('bad json from ' + url + ': ' + body.slice(0, 200)));
          }
        });
      })
      .on('error', reject);
  });
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function main() {
  let pages = [];
  for (let i = 0; i < 40; i++) {
    pages = await getJson(origin + '/json/list');
    if (pages.some(p => p.appId === appName || (p.title || '').includes(appName) || (p.description || '').includes(appName))) break;
    await sleep(250);
  }
  console.log('CDP pages ' + JSON.stringify(pages.map(p => ({id: p.id, title: p.title, appId: p.appId, vm: p.vm, caps: p.reactNative && p.reactNative.capabilities}))));
  const page = pages.find(p => p.appId === appName) || pages[0];
  if (!page) {
    console.log('CDP no_page');
    process.exit(2);
  }
  // Metro's inspector proxy only accepts DevTools from its own origin (or
  // localhost); React Native DevTools, served by Metro, sends exactly that.
  const ws = new WebSocket(page.webSocketDebuggerUrl, {headers: {Origin: origin}});
  let nextId = 1;
  const pending = new Map();
  const events = [];
  ws.on('message', data => {
    const msg = JSON.parse(data.toString());
    if (msg.id && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    } else if (msg.method) {
      events.push(msg);
    }
  });
  await new Promise((res, rej) => {
    ws.on('open', res);
    ws.on('error', rej);
  });
  const call = (method, params = {}, timeoutMs = 8000) =>
    new Promise(resolve => {
      const id = nextId++;
      const t = setTimeout(() => {
        pending.delete(id);
        resolve({timeout: true, method});
      }, timeoutMs);
      pending.set(id, msg => {
        clearTimeout(t);
        resolve(msg);
      });
      ws.send(JSON.stringify({id, method, params}));
    });
  const waitEvent = async (method, ms) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const e = events.find(x => x.method === method);
      if (e) return e;
      await sleep(50);
    }
    return null;
  };

  if (mode === 'hold') {
    const h1 = await call('Runtime.enable');
    const h2 = await call('Debugger.enable');
    const h3 = await call('Runtime.evaluate', {expression: '1 + 2', returnByValue: true});
    const v3 = h3 && h3.result && h3.result.result ? h3.result.result.value : null;
    console.log('CDP hold_attached ' + JSON.stringify({runtime: !h1.error && !h1.timeout, debugger: !h2.error && !h2.timeout, eval: v3}));
    const closed = await new Promise(resolve => {
      const t = setTimeout(() => resolve('still-open'), 40000);
      ws.on('close', code => { clearTimeout(t); resolve('closed:' + code); });
    });
    const detached = events.some(e => e.method === 'Inspector.detached');
    console.log('CDP hold_end ' + JSON.stringify({socket: closed, detached}));
    process.exit(0);
  }
  const r1 = await call('Runtime.enable');
  console.log('CDP runtime_enable ' + JSON.stringify(r1.timeout ? r1 : {ok: !r1.error, error: r1.error}));
  const r2 = await call('Runtime.evaluate', {expression: '1 + 2', returnByValue: true});
  console.log('CDP eval_math ' + JSON.stringify(r2.timeout ? r2 : (r2.result && r2.result.result) || r2.error));
  const r3 = await call('Runtime.evaluate', {expression: 'globalThis.__DEBUG_FIXTURE_MARK', returnByValue: true});
  console.log('CDP eval_global ' + JSON.stringify(r3.timeout ? r3 : (r3.result && r3.result.result) || r3.error));
  const r4 = await call('Runtime.evaluate', {expression: "console.log('CDP_CONSOLE_ROUNDTRIP'); 7", returnByValue: true});
  const ce = await waitEvent('Runtime.consoleAPICalled', 3000);
  console.log('CDP console ' + JSON.stringify(ce ? ce.params.args.map(a => a.value) : null));
  const d1 = await call('Debugger.enable');
  console.log('CDP debugger_enable ' + JSON.stringify(d1.timeout ? d1 : {ok: !d1.error, error: d1.error}));
  const d2 = await call('Debugger.pause');
  const paused = await waitEvent('Debugger.paused', 6000);
  console.log('CDP paused ' + JSON.stringify(paused ? {reason: paused.params.reason, frames: paused.params.callFrames.length} : null));
  const tickBefore = await call('Runtime.evaluate', {expression: 'globalThis.__DEBUG_TICKS', returnByValue: true}, 1500);
  console.log('CDP tick_while_paused ' + JSON.stringify(tickBefore.timeout ? 'blocked' : (tickBefore.result && tickBefore.result.result)));
  const d3 = await call('Debugger.resume');
  console.log('CDP resume ' + JSON.stringify(d3.timeout ? d3 : {ok: !d3.error}));
  await sleep(1200);
  const t1 = await call('Runtime.evaluate', {expression: 'globalThis.__DEBUG_TICKS', returnByValue: true});
  await sleep(1000);
  const t2 = await call('Runtime.evaluate', {expression: 'globalThis.__DEBUG_TICKS', returnByValue: true});
  const v = r => (r && r.result && r.result.result ? r.result.result.value : null);
  console.log('CDP ticks_after_resume ' + JSON.stringify([v(t1), v(t2)]));
  ws.close();
  await sleep(200);
  process.exit(0);
}

main().catch(e => {
  console.log('CDP error ' + JSON.stringify(String(e && e.stack || e)));
  process.exit(3);
});
