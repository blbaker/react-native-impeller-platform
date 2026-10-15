#!/usr/bin/env bash
# FP-02 gate: trace spans -> Chrome/Perfetto JSON (engine/base/Trace.*, model
# flutter/fml/trace_event.h). Staged binary (or RNI_BIN), never rebuilds.
#
#   A  off-mode 300-frame headless run: trace enabled=0 events=0, no file
#   B  --trace-bench: ns per DISABLED span, measured through the engine's macro
#   C  tracing on, headless 300 frames: valid JSON, balanced, spans on the right threads
#   D  off-mode overhead = spans/frame (C) x ns/span (B) / frame time (A) < 1%
#   E  tracing on, windowed 60 frames (xvfb on Linux)
#   F  image-net fixture: ImageFetch/ImageDecode on image-io, ImageUpload on main
#   G  line-height fixture: TextMeasure on js
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail() { echo "TRACE_GATE_FAIL: $*" >&2; exit 1; }
if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"
elif [ "$(uname -s)" = Darwin ]; then BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
[ -x "$BIN" ] || fail "no engine binary at $BIN"
echo "engine: $BIN ($( (shasum -a 256 "$BIN" 2>/dev/null || sha256sum "$BIN") | cut -c1-12))"
ROT="$ROOT/fixtures/native-transform/prebuilt/native-transform.bundle"
IMG="$ROOT/fixtures/image-net/prebuilt/image-net.bundle"
LH="$ROOT/fixtures/eng23-line-height/prebuilt/eng23-line-height.bundle"
for b in "$ROT" "$IMG" "$LH"; do [ -s "$b" ] || fail "missing committed bundle $b"; done

WORK="$(mktemp -d)"; SRV=""
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2> /dev/null; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT
WIN=(); [ "$(uname -s)" = Linux ] && WIN=(xvfb-run -a -f "$WORK/xvfb.auth" -s "-screen 0 1280x1024x24")
run() {  # arm args...
  local arm="$1" rc=0; shift
  ( cd "$(dirname "$BIN")" && timeout 300 "$@" ) > "$WORK/$arm.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$arm.log" >&2; fail "arm $arm exited $rc"; }
}
HL=("$BIN" --headless --probe-banner off --width 400 --height 300 --supersample-rnsvg 0)
check() { local out; out="$(python3 tools/trace_check.py "$@")" || fail "$out"; echo "   $out"; }

echo "== A: tracing off, 300 headless frames =="
run off "${HL[@]}" --bundle "$ROT" --app-name NativeRotateProbe --frames 300
grep -qE '^rn-impeller: trace enabled=0 events=0$' "$WORK/off.log" \
  || fail "off-mode: $(grep -m1 'rn-impeller: trace' "$WORK/off.log" || echo 'no trace line') (expected enabled=0 events=0)"
FRAME_US=$(python3 - "$WORK/off.log" <<'PY'
import re, sys
m = re.search(r"frame_timings .*build_p50=(\d+).*raster_p50=(\d+)", open(sys.argv[1]).read())
print(int(m.group(1)) + int(m.group(2))) if m else sys.exit("no frame_timings line")
PY
) || fail "no frame_timings line in arm A"
echo "   off: enabled=0 events=0, frame build+raster p50 = ${FRAME_US} us"

echo "== B: disabled-span cost =="
NS=$("$BIN" --trace-bench 20000000 | sed -n 's/.*enabled=0 ns_per_span=\([0-9.]*\).*/\1/p')
[ -n "$NS" ] || fail "trace-bench printed no enabled=0 ns_per_span"
echo "   $NS ns per disabled span"

echo "== C: tracing on, 300 headless frames =="
run on "${HL[@]}" --bundle "$ROT" --app-name NativeRotateProbe --frames 300 --trace-out "$WORK/on.json"
grep -qE '^rn-impeller: trace enabled=0 events=[1-9][0-9]* written=1' "$WORK/on.log" || fail "arm C wrote no trace"
# FP-13: the final capture paint is a traced frame too, so --frames 300 = 301 frames.
OUT="$(python3 tools/trace_check.py "$WORK/on.json" --frames 301 --expect NativeAnimatedTick@main:1 --expect NativeAnimatedPump@main:300)" || fail "$OUT"
echo "   $OUT"
SPF=$(echo "$OUT" | sed -n 's/.*spans_per_frame=\([0-9.]*\).*/\1/p')

echo "== D: off-mode overhead =="
python3 - "$SPF" "$NS" "$FRAME_US" <<'PY' || fail "off-mode overhead over 1%"
import sys
spf, ns, frame_us = map(float, sys.argv[1:])
pct = spf * ns / 1000.0 / frame_us * 100.0
print("   overhead = %.2f spans/frame x %.3f ns = %.5f%% of %.0f us" % (spf, ns, pct, frame_us))
sys.exit(0 if pct < 1.0 else 1)
PY

echo "== E: tracing on, windowed 60 frames =="
run win "${WIN[@]}" "$BIN" --window --scale 1 --width 400 --height 300 --supersample-rnsvg 0 \
  --bundle "$ROT" --app-name NativeRotateProbe --frames 60 --trace-out "$WORK/win.json"
# FP-15: windowed RASTER (Raster/Draw/Present) runs on the raster thread.
check "$WORK/win.json" --min-frames 60 --raster-thread --expect NativeAnimatedTick@main:1 --expect Record@main:60

echo "== F: image spans =="
cat > "$WORK/srv.py" <<'PY'
import http.server, struct, zlib
def png(rgb, w=6, h=4):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def ch(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b"")
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = png((255, 0, 0)); self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", 18931), H).serve_forever()
PY
python3 "$WORK/srv.py" > "$WORK/srv.out" 2>&1 & SRV=$!
for _ in $(seq 50); do
  python3 -c 'import socket; socket.create_connection(("127.0.0.1", 18931), 0.2)' 2> /dev/null && break
  kill -0 "$SRV" 2> /dev/null || fail "image server did not start (port 18931 busy?)"; sleep 0.1
done
run img "$BIN" --headless --probe-banner off --bundle "$IMG" --app-name probe --width 440 --height 130 \
  --scale 1 --supersample-rnsvg 0 --trace-out "$WORK/img.json"
check "$WORK/img.json" --expect ImageFetch@image-io:1 --expect ImageDecode@image-io:1 --expect ImageUpload@main:1

echo "== G: text measure span =="
run txt "${HL[@]}" --bundle "$LH" --app-name Eng23LineHeight --frames 3 --trace-out "$WORK/txt.json"
check "$WORK/txt.json" --frames 4 --expect TextMeasure@js:1 --expect MountTransaction@js:1 --expect JsCommit@js:1

echo "TRACE_PASS off+bench+headless+windowed+image+text"
