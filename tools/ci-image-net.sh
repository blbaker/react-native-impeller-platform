#!/usr/bin/env bash
# SC-31 GATE: <Image> network sources, load events, Image statics, cache,
# defaultSource. Headless, node-free: prebuilt fixtures/image-net bundle +
# RNI_BIN, against a local python http server on 127.0.0.1:18931.
# Asserts painted pixels against the expected colours, the fixture's status
# swatches (each one a JS-side check), and the server's request log (the
# in-memory cache means each image URL is requested exactly once).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="${RNI_IMAGE_NET_BUNDLE:-$ROOT/fixtures/image-net/prebuilt/image-net.bundle}"
if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"
elif [ "$(uname -s)" = Darwin ]; then BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
fail() { echo "IMAGE_NET_GATE_FAIL: $*" >&2; exit 1; }
[ -x "$BIN" ] || fail "no engine binary at $BIN"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
command -v python3 > /dev/null || fail "python3 is required"

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2> /dev/null; [ -n "${KEEP_WORKDIR:-}" ] && echo "kept $WORK" >&2 || rm -rf "$WORK"; }
trap cleanup EXIT

cat > "$WORK/server.py" <<'PY'
import http.server, struct, sys, zlib

def png(rgb, w=6, h=4):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

IMAGES = {"/red.png": png((255, 0, 0)), "/yellow.png": png((255, 255, 0)), "/auth.png": png((0, 255, 0))}
LOG = open(sys.argv[1], "a", buffering=1)

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def do_GET(self):
        LOG.write("%s token=%s\n" % (self.path, self.headers.get("X-Token", "-")))
        body = IMAGES.get(self.path)
        if self.path == "/auth.png" and self.headers.get("X-Token") != "sc31":
            body = None
            code = 403
        else:
            code = 200 if body else 404
        body = body or b"not found"
        self.send_response(code)
        self.send_header("Content-Type", "image/png" if code == 200 else "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", 18931), H).serve_forever()
PY
: > "$WORK/requests.log"
. tools/lib/own-port.sh
rni_own_port 18931 "$WORK/server.out" python3 "$WORK/server.py" "$WORK/requests.log" \
  || fail "image server could not own 127.0.0.1:18931 for 2 min"
SERVER_PID="$OWN_PORT_PID"
for _ in $(seq 50); do
  python3 -c 'import socket; socket.create_connection(("127.0.0.1", 18931), 0.2)' 2> /dev/null && break
  kill -0 "$SERVER_PID" 2> /dev/null || { cat "$WORK/server.out" >&2; fail "http server did not start (port 18931 busy?)"; }
  sleep 0.1
done

LOG="$WORK/run.log"
set +e
( cd "$(dirname "$BIN")" && "$BIN" --headless --probe-banner off --bundle "$BUNDLE" --app-name probe \
    --width 440 --height 130 --scale 1 --supersample-rnsvg 0 --screenshot "$WORK/frame.ppm" ) > "$LOG" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { tail -15 "$LOG" >&2; fail "engine exited $rc"; }
grep -q '\[js-exception\]' "$LOG" && { grep '\[js-exception\]' "$LOG" | head -3 >&2; fail "JS exception"; }
[ -s "$WORK/frame.ppm" ] || fail "no screenshot"

# name x y w h expected-rgb  (all regions sit inside one tile/swatch)
python3 - "$WORK/frame.ppm" <<'PY' > "$WORK/pixels.txt" || { cat "$WORK/pixels.txt" >&2; fail "$(grep -m1 FAIL "$WORK/pixels.txt")"; }
import sys
data = open(sys.argv[1], "rb").read()
# P6 header: magic, width, height, maxval, then ONE whitespace byte. The
# background is (32,32,32), so a whitespace-stripping split would eat pixels.
fields, pos = [], 0
while len(fields) < 4:
    while data[pos:pos + 1].isspace():
        pos += 1
    end = pos
    while not data[end:end + 1].isspace():
        end += 1
    fields.append(data[pos:end])
    pos = end
w, h = int(fields[1]), int(fields[2])
px = data[pos + 1:]
def at(x, y):
    i = (y * w + x) * 3
    return tuple(px[i:i + 3])
CHECKS = [
    ("T0 remote image", 12, 12, 56, 56, (255, 0, 0)),
    ("T1 request headers", 82, 12, 56, 56, (0, 255, 0)),
    ("T2 defaultSource", 152, 12, 56, 56, (0, 0, 255)),
    ("T3 prefetched image", 222, 12, 56, 56, (255, 255, 0)),
    ("S0 load events", 12, 82, 56, 26, (0, 255, 0)),
    ("S1 error events", 82, 82, 56, 26, (0, 255, 0)),
    ("S2 getSize", 152, 82, 56, 26, (0, 255, 0)),
    ("S3 prefetch/queryCache", 222, 82, 56, 26, (0, 255, 0)),
]
bad = 0
for name, x0, y0, cw, ch, want in CHECKS:
    off = 0
    worst = None
    for y in range(y0, y0 + ch):
        for x in range(x0, x0 + cw):
            p = at(x, y)
            if max(abs(a - b) for a, b in zip(p, want)) > 8:
                off += 1
                worst = worst or (x, y, p)
    if off:
        bad += 1
        print("FAIL %s: %d px off %s, first (%d,%d)=%s" % (name, off, want, *worst))
    else:
        print("ok %s" % name)
sys.exit(1 if bad else 0)
PY

# The cache: every image URL crosses the wire once (the image and getSize on
# red.png share one fetch; the prefetched yellow.png is not fetched again).
count() { grep -c "^$1 " "$WORK/requests.log" || true; }
[ "$(count /red.png)" = 1 ] || fail "cache: /red.png requested $(count /red.png) times, expected 1"
[ "$(count /yellow.png)" = 1 ] || fail "cache: /yellow.png requested $(count /yellow.png) times, expected 1"
grep -q '^/auth.png token=sc31$' "$WORK/requests.log" || fail "headers: /auth.png never sent X-Token: sc31"
grep -q '^/auth.png token=-$' "$WORK/requests.log" && fail "headers: an /auth.png request went out without X-Token"
grep -q 'net_in_flight=0' "$LOG" || fail "image loads still in flight at capture ($(grep -o 'net_in_flight=[0-9]*' "$LOG"))"
echo "IMAGE_NET_GATE_PASS ($(grep -c '^ok ' "$WORK/pixels.txt") regions, $(wc -l < "$WORK/requests.log") requests, $(grep -o 'net_requests_completed=[0-9]*' "$LOG"))"
