#!/usr/bin/env node
// The P10 gate's HTTP server. A separate file, not an inline `node -e`, for
// the reason tools/fixture-probe-args.js exists: inline server blocks get
// hand-copied into the next gate and drift from the fixture they answer.
//
// It binds an EPHEMERAL port and prints it on stdout as `PORT=<n>` so the gate
// never guesses. A hardcoded port is a flaky gate on a shared machine and a
// silently-wrong one if something else is already listening.
//
// It ECHOES what it received on /post rather than replying with a canned OK,
// because "the server answered 200" and "the server got the headers and body
// the client claimed to send" are different assertions, and only the second
// one catches a transport that drops them.
'use strict';
const http = require('http');
const path = require('path');

const fixturePath = process.argv[2];
if (!fixturePath) {
  console.error('usage: p10-server.js <fixture.json>');
  process.exit(2);
}
const g = require(path.resolve(fixturePath));

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => (body += chunk));
  req.on('end', () => {
    // Set on EVERY reply: the fixture asserts response headers survive the
    // native -> JS event, which a body-only implementation silently drops.
    res.setHeader(g.responseHeaders.expectHeader, g.responseHeaders.expectHeaderValue);

    if (req.url.startsWith('/get')) {
      res.setHeader('Content-Type', 'text/plain');
      res.writeHead(200);
      res.end(g.getRequest.expectBody);
      return;
    }

    if (req.url.startsWith('/status')) {
      // Deliberately NOT 200. A module that hardcoded 200 — or a JS fallback
      // inventing a default — passes a body assertion and fails this one.
      res.writeHead(g.getStatus.expectStatus);
      res.end('teapot');
      return;
    }

    if (req.url.startsWith('/post')) {
      res.setHeader('Content-Type', 'application/json');
      res.writeHead(200);
      res.end(JSON.stringify({
        method: req.method,
        header: req.headers[g.postRequest.sendHeader.toLowerCase()] ?? null,
        body,
      }));
      return;
    }

    res.writeHead(404);
    res.end('no');
  });
});

server.listen(0, '127.0.0.1', () => {
  console.log(`PORT=${server.address().port}`);
});

// The gate kills this process; without a guard an unhandled client reset would
// take the server down mid-run and look like a networking defect.
server.on('clientError', (err, socket) => {
  try { socket.destroy(); } catch (e) { console.error('p10-server: destroy after clientError:', e.message); }
});
process.on('SIGTERM', () => server.close(() => process.exit(0)));
