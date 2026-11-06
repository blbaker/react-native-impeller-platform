#!/usr/bin/env python3
"""Fixture server for tools/ci-webview.sh (stdlib only).

  webview_server.py <port> <pages-dir> <request-log>

Serves <pages-dir>. Every request appends `REQ <path> gate=<X-Rni-Gate or ->`
to <request-log>, so the gate can prove source.headers rode on the top-level
request and NOT on its subresources. /slow answers after 8 s (stopLoading arm).
"""
import http.server
import os
import sys
import time

PORT, ROOT, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def log_message(self, *a):
        pass

    def do_GET(self):
        with open(LOG, "a") as f:
            f.write("REQ %s gate=%s\n" % (self.path, self.headers.get("X-Rni-Gate", "-")))
        if self.path.startswith("/slow"):
            time.sleep(8)
            body = b"<!doctype html><title>slow</title>slow"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except OSError:
                pass
            return
        super().do_GET()


class Server(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    open(LOG, "a").close()
    Server(("127.0.0.1", PORT), Handler).serve_forever()
