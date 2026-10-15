/**
 * RELAY-SPIKE: can this engine carry the HostApp relay's client half?
 *
 * Two capabilities, measured for real, not by symbol:
 *   WebSocket   a socket to ws://127.0.0.1:8797/ (the echo server
 *               tools/relay-probe.py starts) opens, and a text frame and a
 *               binary frame both come back unchanged.
 *   RANDOM      globalThis.crypto.getRandomValues exists and two 32 byte
 *               draws are not all zero and not equal.
 *
 * Bands, so the pixels and the log agree:
 *   CONTROL  green, always painted. No green means the harness is broken.
 *   SUBJECT  red only after the run settles with BOTH capabilities working.
 */
// ENG-31: the macOS tester's probe (peer the macOS tester), VERBATIM. Do not
// edit; tools/ci-crypto.sh arm B runs it against tools/crypto_check.py's
// ws echo server on 8797 (the port is hardcoded here).
const React = require('react');
const { AppRegistry, View, Text, TurboModuleRegistry } = require('react-native');

const URL_ = 'ws://127.0.0.1:8797/';
const GREEN = 'rgb(0, 255, 0)';
const RED = 'rgb(255, 0, 0)';
const BLACK = 'rgb(0, 0, 0)';
const DEADLINE_MS = 8000;
const ORDER = ['ws', 'WebSocketModule', 'ws-open', 'ws-text', 'ws-binary', 'crypto-bare', 'crypto', 'grv', 'grv-call', 'settled'];

const notes = {};
let onSettled = null;
let settledOk = false;

const msg = (e) => String((e && e.message) || e).slice(0, 60).replace(/\s+/g, '_');
const line = () => 'RELAY_NOTES ' + ORDER.map((k) => k + '=' + (k in notes ? notes[k] : 'MISSING')).join(' ');

function probeRandom() {
  try {
    notes['crypto-bare'] = typeof crypto;
  } catch (e) {
    notes['crypto-bare'] = 'THROWS';
  }
  try {
    const c = globalThis.crypto;
    notes.crypto = c === undefined ? 'undefined' : typeof c;
    const grv = c ? c.getRandomValues : undefined;
    notes.grv = typeof grv === 'function' ? 'function' : 'absent';
    if (typeof grv !== 'function') {
      notes['grv-call'] = 'skipped';
      return;
    }
    try {
      const a = new Uint8Array(32);
      const b = new Uint8Array(32);
      c.getRandomValues(a);
      c.getRandomValues(b);
      const zero = a.every((x) => x === 0);
      const same = a.every((x, i) => x === b[i]);
      notes['grv-call'] = zero ? 'ZEROS' : same ? 'REPEATS' : 'ok';
    } catch (e) {
      notes['grv-call'] = 'THREW(' + msg(e) + ')';
    }
  } catch (e) {
    notes.crypto = 'THROWS';
    notes.grv = 'THROWS';
    notes['grv-call'] = 'skipped';
  }
}

function settle(how) {
  if (notes.settled) return;
  notes.settled = how;
  settledOk = notes['ws-open'] === 'ok' && notes['ws-text'] === 'ok' && notes['grv-call'] === 'ok';
  console.log(line());
  if (onSettled) onSettled(settledOk);
}

function probeWebSocket() {
  notes.ws = typeof WebSocket;
  try {
    notes.WebSocketModule = TurboModuleRegistry.get('WebSocketModule') ? 'present' : 'null';
  } catch (e) {
    notes.WebSocketModule = 'THREW';
  }
  notes['ws-open'] = 'UNSETTLED';
  notes['ws-text'] = 'UNSETTLED';
  notes['ws-binary'] = 'UNSETTLED';
  if (typeof WebSocket !== 'function') {
    notes['ws-open'] = notes['ws-text'] = notes['ws-binary'] = 'skipped';
    settle('events');
    return;
  }
  let sock;
  try {
    sock = new WebSocket(URL_);
  } catch (e) {
    notes['ws-open'] = 'THREW(' + msg(e) + ')';
    settle('events');
    return;
  }
  const TEXT = 'relay-probe-text-1';
  const BIN = [1, 2, 3, 250, 251, 252];
  const done = () => {
    try {
      sock.close();
    } catch (e) {
      // already closed
    }
    settle('events');
  };
  try {
    sock.binaryType = 'arraybuffer';
  } catch (e) {
    notes['ws-binary'] = 'NO_ARRAYBUFFER(' + msg(e) + ')';
  }
  sock.onopen = () => {
    notes['ws-open'] = 'ok';
    sock.send(TEXT);
  };
  sock.onmessage = (ev) => {
    if (typeof ev.data === 'string') {
      notes['ws-text'] = ev.data === TEXT ? 'ok' : 'WRONG';
      try {
        sock.send(new Uint8Array(BIN).buffer);
      } catch (e) {
        notes['ws-binary'] = 'THREW(' + msg(e) + ')';
        done();
      }
      return;
    }
    if (ev.data instanceof ArrayBuffer) {
      const got = Array.from(new Uint8Array(ev.data));
      notes['ws-binary'] = got.join(',') === BIN.join(',') ? 'ok' : 'WRONG';
    } else {
      notes['ws-binary'] = 'TYPE(' + typeof ev.data + ')';
    }
    done();
  };
  sock.onerror = (e) => {
    if (notes['ws-open'] === 'UNSETTLED') notes['ws-open'] = 'ERROR(' + msg(e) + ')';
    done();
  };
}

probeRandom();
probeWebSocket();
setTimeout(() => settle('deadline'), DEADLINE_MS);

function Probe() {
  const [ok, setOk] = React.useState(settledOk);
  React.useEffect(() => {
    onSettled = setOk;
    if (notes.settled) setOk(settledOk);
  }, []);
  return React.createElement(
    View,
    { style: { flex: 1, backgroundColor: BLACK, padding: 20 } },
    React.createElement(View, { style: { width: 400, height: 50, backgroundColor: GREEN } }),
    React.createElement(Text, { style: { fontSize: 30, color: GREEN } }, 'RELAY'),
    React.createElement(View, { style: { width: 400, height: 50, backgroundColor: ok ? RED : BLACK } }),
  );
}

AppRegistry.registerComponent('probe', () => Probe);
