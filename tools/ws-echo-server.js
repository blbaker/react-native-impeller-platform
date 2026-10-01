#!/usr/bin/env node
// Tiny ws:// echo server for tools/ci-dev-boot.sh (parity item 12).
// Prints `WS_ECHO_PORT <port>` once listening, echoes every message with its
// original type (text stays text, binary stays binary), exits after 30 s.
// Uses the `ws` package already in the base app (Metro depends on it).
const path = require('path');
const app = process.argv[2];
const WebSocket = require(path.join(app, 'node_modules', 'ws'));
const wss = new WebSocket.Server({host: '127.0.0.1', port: 0}, () => {
  console.log('WS_ECHO_PORT ' + wss.address().port);
});
wss.on('connection', (sock) => {
  console.log('WS_ECHO_CONNECTION');
  sock.on('message', (data) => {
    const binary = typeof data !== 'string';
    console.log('WS_ECHO_GOT ' + (binary ? 'binary ' + data.length : 'text ' + data));
    sock.send(data, {binary});
  });
});
setTimeout(() => process.exit(0), 30000);
