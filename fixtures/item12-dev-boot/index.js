/**
 * parity item 12 fixture: a __DEV__ bundle boots, and app WebSockets work.
 *
 * Built with --dev true. It renders a View and, if the launch URL names a
 * ws:// echo server (passed by the gate via --initial-url), opens a
 * WebSocket to it, sends text + binary, and logs each stage:
 *   WS_OPEN, WS_ECHO_TEXT <data>, WS_ECHO_BINARY <bytes>, WS_CLOSED <code>
 * WS_BAD_SCHEME proves a wss:// URL fails loudly instead of hanging.
 */
import React from 'react';
import {AppRegistry, Linking, Text, View} from 'react-native';

console.log('DEV_BOOT dev=' + String(__DEV__));
// A warning on purpose: in __DEV__ it raises a LogBox toast, whose dismiss
// button renders an <Image> -- the path that crashed before the Image shim.
console.warn('DEVBOOT_WARN this toast must render');

function runEcho(url) {
  const ws = new WebSocket(url);
  ws.binaryType = 'arraybuffer';
  let step = 0;
  ws.onopen = () => {
    console.log('WS_OPEN');
    ws.send('hello-impeller');
  };
  ws.onmessage = e => {
    if (step === 0) {
      console.log('WS_ECHO_TEXT ' + e.data);
      step = 1;
      ws.send(new Uint8Array([1, 2, 250]).buffer);
    } else {
      const bytes = Array.from(new Uint8Array(e.data)).join(',');
      console.log('WS_ECHO_BINARY ' + bytes);
      ws.close(1000, 'done');
    }
  };
  ws.onclose = e => console.log('WS_CLOSED ' + e.code);
  ws.onerror = e => console.log('WS_ERROR ' + (e && e.message));
}

Linking.getInitialURL().then(url => {
  const m = url && url.match(/[?&]ws=([^&]+)/);
  if (m) runEcho(decodeURIComponent(m[1]));
  // RN delivers a websocketFailed message as the CLOSE event's reason (code
  // 1006); the 'error' event itself carries no message.
  const bad = new WebSocket('wss://127.0.0.1:9/never');
  bad.onclose = e => console.log('WS_BAD_SCHEME ' + e.code + ' ' + e.reason);
});

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      <Text style={{color: '#ffffff'}}>dev boot</Text>
    </View>
  );
}

AppRegistry.registerComponent('Item12DevBoot', () => Fixture);
