#!/usr/bin/env bash
# FP-13 RECORD / RASTER SPLIT GATE (model: flutter LayerTree -> shell/common/
# pipeline.h -> Rasterizer). The split is a pure refactor, so:
#
#   P  pixels: 6 fixtures x supersample {0,4} render per-pixel identical to the
#      pre-pass binary. Headless: style grid, text, svg, world sprites, images,
#      native transform (frame 1 and frame 21). Windowed: native transform
#      captured at frame 30 of a running animation, which is where a raster
#      that lags its record by one frame shows.
#      Reference: RNI_REF_BIN=<pre-pass rn-impeller> renders the same cases and
#      diffs pixel by pixel; without it the sha256 of each pre-pass render in
#      tools/record-raster-golden.txt is the reference (linux x64 llvmpipe only).
#      RECORD_RASTER_WRITE_GOLDEN=1 + RNI_REF_BIN rewrites that file.
#      The style grid's ActivityIndicator spins with the wall clock, so every
#      ActivityIndicatorView box the run reports (node_frame) is zeroed in both
#      modes before comparing; each line prints masked=<pixels>.
#   F  frame records: headless and windowed runs with --trace-out and
#      --frame-timings-out show RECORD and RASTER as separate stamped phases
#      per frame (tools/record_raster_check.py frames).
#
# Node-free (committed prebuilt bundles). Engine: RNI_BIN or the staged linux
# package (never rebuilt here). Windowed runs use the job's private DISPLAY.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail() { echo "RECORD_RASTER FAIL $*"; exit 1; }

BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$BIN" ] || fail "setup: no engine at $BIN"
REF="${RNI_REF_BIN:-}"
GOLDEN="$ROOT/tools/record-raster-golden.txt"
WRITE="${RECORD_RASTER_WRITE_GOLDEN:-0}"
if [ "$WRITE" = 1 ] && [ -z "$REF" ]; then fail "setup: RECORD_RASTER_WRITE_GOLDEN needs RNI_REF_BIN"; fi
if [ -z "$REF" ]; then
  [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || fail "setup: golden hashes are linux x64 only; set RNI_REF_BIN"
  [ -s "$GOLDEN" ] || fail "setup: no $GOLDEN"
fi
echo "engine: $BIN ($(sha256sum "$BIN" | cut -c1-12))${REF:+ ref: $REF ($(sha256sum "$REF" | cut -c1-12))}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-record-raster.XXXX")"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "kept $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

FX="$ROOT/fixtures"
FONTS="$FX/eng22-font-family/fonts"
# name | mode | bundle | app | args
CASES=(
  "grid|h|style-audit/prebuilt/style-audit.bundle|probe|--width 1200 --height 2100 --initial-url probe://grid"
  "text|h|eng22-font-family/prebuilt/eng22-font-family.bundle|Eng22FontFamily|--width 400 --height 300 --font-dir $FONTS"
  "svg|h|eng-supersample/prebuilt/eng-supersample.bundle|EngSupersample|"
  "sprites|h|eng10-world-sprites/prebuilt/eng10-world-sprites.bundle|Eng10Sprites|--width 320 --height 240"
  "images|h|image-net/prebuilt/image-net.bundle|probe|--width 440 --height 130 --scale 1"
  "ntx|h|native-transform/prebuilt/native-transform.bundle|NativeRotateProbe|--width 400 --height 300 --frames 21"
  "ntx-window|w|native-transform/prebuilt/native-transform.bundle|NativeRotateProbe|--width 400 --height 300 --frames 60 --screenshot-after-frames 30"
)

# Local image server for the images case (same content as ci-image-net). The
# port is fixed by the bundle; wait for it if another gate holds it.
cat > "$WORK/server.py" <<'PY'
import http.server, struct, zlib
def png(rgb, w=6, h=4):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
IMAGES = {"/red.png": png((255, 0, 0)), "/yellow.png": png((255, 255, 0)), "/auth.png": png((0, 255, 0))}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def do_GET(self):
        body = IMAGES.get(self.path)
        if self.path == "/auth.png" and self.headers.get("X-Token") != "sc31":
            body = None
        code = 200 if body else 404
        body = body or b"not found"
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", 18931), H).serve_forever()
PY
. tools/lib/own-port.sh
rni_own_port 18931 "$WORK/server.out" python3 "$WORK/server.py" \
  || fail "setup: image server could not own 127.0.0.1:18931 for 2 min"
SERVER_PID="$OWN_PORT_PID"

render() {  # bin case-line ss out-prefix [extra...]
  local bin="$1" line="$2" ss="$3" out="$4"; shift 4
  local name mode bundle app args rc=0
  IFS='|' read -r name mode bundle app args <<< "$line"
  # shellcheck disable=SC2206
  local a=(--bundle "$FX/$bundle" --app-name "$app" --probe-banner off --supersample-rnsvg "$ss" $args "$@")
  if [ "$mode" = h ]; then
    [[ "$args" == *--frames* ]] && a+=(--screenshot-first "$out.first.ppm")
    ( cd "$(dirname "$bin")" && timeout 300 "$bin" --headless "${a[@]}" --screenshot "$out.ppm" ) \
      > "$out.log" 2>&1 || rc=$?
  else
    ( cd "$(dirname "$bin")" && timeout 300 xvfb-run -a -f "$WORK/xvfb.auth" -s "-screen 0 1280x1024x24" \
        "$bin" --window --scale 1 "${a[@]}" --screenshot "$out.ppm" ) > "$out.log" 2>&1 || rc=$?
  fi
  [ "$rc" -eq 0 ] || { tail -12 "$out.log"; fail "P $name ss=$ss: engine exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$out.log" || fail "P $name ss=$ss: nothing mounted"
  grep -q "^rn-impeller: supersample_rnsvg=$ss" "$out.log" || fail "P $name ss=$ss: supersample not $ss"
  [ -s "$out.ppm" ] || fail "P $name ss=$ss: no screenshot"
}

echo "== P. pixels vs the pre-pass binary (${REF:+ref binary}${REF:-golden hashes}) =="
[ "$WRITE" = 1 ] && : > "$WORK/golden.new"
compared=0
for ss in 0 4; do
  for line in "${CASES[@]}"; do
    name="${line%%|*}"; key="$name-ss$ss"
    render "$BIN" "$line" "$ss" "$WORK/$key"
    shots=("$key"); [ -s "$WORK/$key.first.ppm" ] && shots+=("$key.first")
    if [ -n "$REF" ]; then render "$REF" "$line" "$ss" "$WORK/ref-$key"; fi
    for s in "${shots[@]}"; do
      c="$(python3 tools/record_raster_check.py colors "$WORK/$s.ppm")" || fail "P $s is blank ($c)"
      if [ -n "$REF" ]; then
        out="$(python3 tools/record_raster_check.py diff "$WORK/$s.ppm" "$WORK/ref-$s.ppm" "$WORK/$key.log")" \
          || { cp "$WORK/$s.ppm" "$WORK/ref-$s.ppm" /tmp/ 2>/dev/null || true; fail "P pixels differ: $s $out"; }
        [ "$WRITE" = 1 ] && echo "$s $(python3 tools/record_raster_check.py hash "$WORK/ref-$s.ppm" "$WORK/ref-$key.log" | cut -d' ' -f1)" >> "$WORK/golden.new"
      else
        want="$(awk -v k="$s" '$1 == k {print $2}' "$GOLDEN")"
        [ -n "$want" ] || fail "P no golden for $s"
        read -r got m <<< "$(python3 tools/record_raster_check.py hash "$WORK/$s.ppm" "$WORK/$key.log")"
        [ "$got" = "$want" ] || { cp "$WORK/$s.ppm" "/tmp/record-raster-$s.ppm"; fail "P pixels differ: $s sha256 $got vs pre-pass $want (kept /tmp/record-raster-$s.ppm)"; }
        out="sha256 match $m"
      fi
      compared=$((compared + 1))
      echo "   $s: $out, $c"
    done
  done
done
if [ "$WRITE" = 1 ]; then
  { echo "# FP-13 pre-pass renders (sha256 of the ppm), ref $(sha256sum "$REF" | cut -c1-12). Regenerate:"
    echo "# RNI_REF_BIN=<pre-change rn-impeller> RECORD_RASTER_WRITE_GOLDEN=1 bash tools/ci-record-raster.sh"
    echo "# key = sha256(\"WxH:\" + rgb with ActivityIndicatorView boxes zeroed), see record_raster_check.py hash"
    cat "$WORK/golden.new"; } > "$GOLDEN"
  echo "   wrote $GOLDEN"
fi

echo "== F. frame records: RECORD and RASTER are separate stamped phases =="
for line in "${CASES[5]}" "${CASES[6]}"; do
  name="${line%%|*}"
  render "$BIN" "$line" 0 "$WORK/f-$name" --trace-out "$WORK/f-$name.trace.json" \
    --frame-timings-out "$WORK/f-$name.timings.json"
  out="$(python3 tools/record_raster_check.py frames "$WORK/f-$name.log" \
    "$WORK/f-$name.trace.json" "$WORK/f-$name.timings.json")" || fail "F $name: $out"
  echo "   $name: $out"
done

echo "RECORD_RASTER PASS ($compared captures identical to the pre-pass binary; record/raster phases stamped)"
