#!/usr/bin/env python3
"""Test media server for tools/ci-video-net.sh (ImpellerVideo over the network).

  video_net_server.py --root DIR --port N --log FILE [--cert PEM --key PEM]
                      [--live DIR] [--live-seg SECONDS]

Serves DIR over http (or https with --cert/--key) with byte ranges (206), 404
for anything missing, and logs one JSON line per request (path, range, status,
bytes sent). Special paths:
  /stall/...              accepts the request and never answers (a hung server)
  /slow/<path>            <path>, but the FIRST request of each path waits --slow-ms first
  /lag/<path>             <path>, every request waits --lag-ms first (HLS: each segment)
  /throttle/<path>        <path>, body sent at --throttle-bps bytes per second
  /live/<v>/index.m3u8    a LIVE playlist over the pre-cut segments in
                          <live>/<v>/segNNNNN.ts: a 4-segment window that moves
                          one segment every --live-seg seconds, no ENDLIST
The socket is bound before READY is printed, so a READY with a dead port
cannot happen.
"""
import argparse
import http.server
import json
import os
import re
import ssl
import sys
import threading
import time

ARGS = None
T0 = time.time()
LOG_LOCK = threading.Lock()
WINDOW = 4
SLOW_SEEN = set()


def log(rec):
    rec['t'] = round(time.time() - T0, 3)
    with LOG_LOCK, open(ARGS.log, 'a') as f:
        f.write(json.dumps(rec) + '\n')


def live_playlist(variant):
    d = os.path.join(ARGS.live, variant)
    segs = sorted(n for n in os.listdir(d) if n.endswith('.ts'))
    if not segs:
        return None
    seq = int((time.time() - T0) / ARGS.live_seg)
    lines = ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:%d' % round(ARGS.live_seg),
             '#EXT-X-MEDIA-SEQUENCE:%d' % seq]
    for i in range(seq, seq + WINDOW):
        lines += ['#EXTINF:%.3f,' % ARGS.live_seg, segs[i % len(segs)]]
    return ('\n'.join(lines) + '\n').encode()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def send_body(self, code, body, ctype, extra=None):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split('?', 1)[0]
        rng = self.headers.get('Range')
        rec = {'path': path, 'query': '?' in self.path, 'range': rng, 'ua': self.headers.get('User-Agent')}
        if path.startswith('/stall/'):
            log(dict(rec, status='stall'))
            while True:  # until the client goes away (the read below fails)
                time.sleep(0.2)
                try:
                    self.connection.settimeout(0.01)
                    if self.connection.recv(1, 0) == b'':
                        return
                except (TimeoutError, ssl.SSLWantReadError, BlockingIOError):
                    continue
                except OSError:
                    return
        m = re.match(r'^/live/([A-Za-z0-9_-]+)/index\.m3u8$', path)
        if m and ARGS.live:
            body = live_playlist(m.group(1))
            if body is None:
                log(dict(rec, status=404))
                return self.send_body(404, b'no live variant\n', 'text/plain')
            log(dict(rec, status=200, bytes=len(body)))
            return self.send_body(200, body, 'application/vnd.apple.mpegurl', {'Cache-Control': 'no-cache'})
        throttle = 0
        if path.startswith('/lag/'):  # every request waits --lag-ms (HLS: per segment)
            path = path[len('/lag'):]
            time.sleep(ARGS.lag_ms / 1000.0)
        if path.startswith('/slow/'):
            path = path[len('/slow'):]
            with LOG_LOCK:
                first = path not in SLOW_SEEN
                SLOW_SEEN.add(path)
            if first:
                time.sleep(ARGS.slow_ms / 1000.0)
        elif path.startswith('/throttle/'):
            path = path[len('/throttle'):]
            throttle = ARGS.throttle_bps
        if m is None and path.startswith('/live/') and ARGS.live:
            fs = os.path.join(ARGS.live, os.path.normpath(path[len('/live/'):]).lstrip('/'))
        else:
            fs = os.path.join(ARGS.root, os.path.normpath(path).lstrip('/'))
        if not os.path.isfile(fs):
            log(dict(rec, status=404))
            return self.send_body(404, b'not found\n', 'text/plain')
        size = os.path.getsize(fs)
        start, end, code = 0, size - 1, 200
        if rng:
            mm = re.match(r'^bytes=(\d*)-(\d*)$', rng.strip())
            if not mm or (mm.group(1) == '' and mm.group(2) == ''):
                log(dict(rec, status=416))
                return self.send_body(416, b'', 'text/plain', {'Content-Range': 'bytes */%d' % size})
            if mm.group(1) == '':
                start = max(0, size - int(mm.group(2)))
            else:
                start = int(mm.group(1))
                if mm.group(2):
                    end = min(size - 1, int(mm.group(2)))
            if start >= size:
                log(dict(rec, status=416))
                return self.send_body(416, b'', 'text/plain', {'Content-Range': 'bytes */%d' % size})
            code = 206
        n = end - start + 1
        ctype = 'application/vnd.apple.mpegurl' if fs.endswith('.m3u8') else \
            'video/mp2t' if fs.endswith('.ts') else 'video/mp4'
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(n))
        if code == 206:
            self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
        self.end_headers()
        sent = 0
        if self.command != 'HEAD':
            t_start = time.time()
            with open(fs, 'rb') as f:
                f.seek(start)
                try:
                    while sent < n:
                        chunk = f.read(min(16384 if throttle else 65536, n - sent))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        sent += len(chunk)
                        if throttle:  # hold the average at the limit
                            ahead = sent / throttle - (time.time() - t_start)
                            if ahead > 0:
                                time.sleep(ahead)
                except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                    pass
        log(dict(rec, status=code, start=start, bytes=sent))


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    tls = None

    def get_request(self):
        sock, addr = self.socket.accept()
        if self.tls is None:
            return sock, addr
        try:  # handshake here, so a client that refuses our cert is LOGGED
            return self.tls.wrap_socket(sock, server_side=True), addr
        except (ssl.SSLError, OSError) as e:
            log({'path': None, 'status': 'tls_handshake_failed', 'error': str(e)[:200]})
            sock.close()
            raise OSError('handshake failed')

    def handle_error(self, request, client_address):
        log({'path': None, 'status': 'conn_error', 'error': repr(sys.exc_info()[1])[:200]})


def main():
    global ARGS
    p = argparse.ArgumentParser()
    p.add_argument('--root', required=True)
    p.add_argument('--port', type=int, required=True)
    p.add_argument('--log', required=True)
    p.add_argument('--cert')
    p.add_argument('--key')
    p.add_argument('--live')
    p.add_argument('--live-seg', type=float, default=2.0)
    p.add_argument('--slow-ms', type=int, default=1500)
    p.add_argument('--lag-ms', type=int, default=800)
    p.add_argument('--throttle-bps', type=int, default=250000)
    ARGS = p.parse_args()
    srv = Server(('0.0.0.0', ARGS.port), Handler)
    if ARGS.cert:
        srv.tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        srv.tls.load_cert_chain(ARGS.cert, ARGS.key)
    print('READY port=%d tls=%d' % (ARGS.port, 1 if ARGS.cert else 0), flush=True)
    srv.serve_forever()


if __name__ == '__main__':
    main()
