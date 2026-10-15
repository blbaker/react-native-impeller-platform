#!/usr/bin/env bash
# FP-14 RECORD MAKES NO GL CALL (model: Flutter's UI thread owns no GL context;
# GPU work for a recorded picture is deferred to the raster thread, e.g.
# lib/ui/painting/display_list_deferred_image_gpu_impeller.cc).
#
# Every case runs with RNI_ASSERT_NO_GL_IN_RECORD=1 (the host releases its
# context around RECORD and aborts if one is current inside it) and with an
# LD_PRELOAD GL proc-table shim (tools/lib/gl-count-shim.sh) that counts GL
# calls per thread through trampolines on every gl* the process can reach.
#   S  shim alive: overflow=0, Impeller's proc table went through it
#      (proc_slots >= 50) and RASTER counted GL calls (raster_calls > 0).
#   R  record: `record_gl calls=0`, every RECORD ran with the context released
#      (released == frames > 0), no name-pool starvation, no failed job.
#   C  coverage: the GPU paths really ran as raster jobs (image uploads on the
#      images case, sprite uploads, supersample offscreens at ss 1 and 4).
#   P  pixels: 6 core fixtures (style grid, text, svg, world sprites, images,
#      native transform headless + windowed) x supersample {0,1,4} are
#      identical to the pre-pass (FP-13) binary: RNI_REF_BIN=<old rn-impeller>
#      diffs per pixel, else tools/record-no-gl-golden.txt (sha256 of the
#      pre-pass renders, linux x64 llvmpipe; RECORD_NO_GL_WRITE_GOLDEN=1 +
#      RNI_REF_BIN rewrites it). ActivityIndicator boxes are zeroed (wall clock).
# RECORD_NO_GL_ONLY="grid sprites" limits the fixtures (mutation runs).
#
# Node-free (committed prebuilt bundles). Engine: RNI_BIN or the staged linux
# package. The shim needs linux x86_64 and a C compiler.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail() { echo "RECORD_NO_GL FAIL $*"; exit 1; }

BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$BIN" ] || fail "setup: no engine at $BIN"
REF="${RNI_REF_BIN:-}"
GOLDEN="$ROOT/tools/record-no-gl-golden.txt"
WRITE="${RECORD_NO_GL_WRITE_GOLDEN:-0}"
if [ "$WRITE" = 1 ] && [ -z "$REF" ]; then fail "setup: RECORD_NO_GL_WRITE_GOLDEN needs RNI_REF_BIN"; fi
[ -n "$REF" ] || [ -s "$GOLDEN" ] || fail "setup: no $GOLDEN"
echo "engine: $BIN ($(sha256sum "$BIN" | cut -c1-12))${REF:+ ref: $REF}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-record-no-gl.XXXX")"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "kept $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

# shellcheck source=lib/gl-count-shim.sh
source "$ROOT/tools/lib/gl-count-shim.sh"
gl_shim_build "$BIN" "$WORK/shim" > "$WORK/shim-build.log" 2>&1 \
  || { tail -5 "$WORK/shim-build.log"; fail "setup: GL shim did not build (linux x86_64 + cc only)"; }
SHIM="$WORK/shim/libglcount.so"
echo "shim: $(wc -l < "$WORK/shim/direct.txt") direct gl* imports"

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
ONLY="${RECORD_NO_GL_ONLY:-}"

# Local image server for the images case (same content as ci-image-net).
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
for _ in $(seq 120); do
  python3 "$WORK/server.py" > "$WORK/server.out" 2>&1 &
  SERVER_PID=$!
  sleep 0.3
  kill -0 "$SERVER_PID" 2>/dev/null && break
  SERVER_PID=""; sleep 1
done
[ -n "$SERVER_PID" ] || fail "setup: image server could not bind 127.0.0.1:18931 for 2 min"

render() {  # bin case-line ss out-prefix shim(0|1)
  local bin="$1" line="$2" ss="$3" out="$4" shim="$5"
  local name mode bundle app args rc=0
  IFS='|' read -r name mode bundle app args <<< "$line"
  # shellcheck disable=SC2206
  local a=(--bundle "$FX/$bundle" --app-name "$app" --probe-banner off --supersample-rnsvg "$ss" $args)
  local pre=(env)
  [ "$shim" = 1 ] && pre=(env RNI_ASSERT_NO_GL_IN_RECORD=1 LD_PRELOAD="$SHIM")
  if [ "$mode" = h ]; then
    [[ "$args" == *--frames* ]] && a+=(--screenshot-first "$out.first.ppm")
    ( cd "$(dirname "$bin")" && timeout 300 "${pre[@]}" "$bin" --headless "${a[@]}" --screenshot "$out.ppm" ) \
      > "$out.log" 2>&1 || rc=$?
  else
    ( cd "$(dirname "$bin")" && timeout 300 xvfb-run -a -f "$WORK/xvfb.auth" -s "-screen 0 1280x1024x24" \
        "${pre[@]}" "$bin" --window --scale 1 "${a[@]}" --screenshot "$out.ppm" ) > "$out.log" 2>&1 || rc=$?
  fi
  [ "$rc" -eq 0 ] || { tail -12 "$out.log"; fail "$name ss=$ss: engine exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$out.log" || fail "$name ss=$ss: nothing mounted"
  [ -s "$out.ppm" ] || fail "$name ss=$ss: no screenshot"
}

field() { sed -nE "s/^rn-impeller: record_gl .*\\b$2=([0-9]+).*/\\1/p" "$1" | tail -1; }

[ "$WRITE" = 1 ] && : > "$WORK/golden.new"
runs=0 compared=0 ups=0 offs=0
for ss in 0 1 4; do
  for line in "${CASES[@]}"; do
    name="${line%%|*}"; key="$name-ss$ss"
    if [ -n "$ONLY" ] && [[ " $ONLY " != *" $name "* ]]; then continue; fi
    render "$BIN" "$line" "$ss" "$WORK/$key" 1
    log="$WORK/$key.log"
    # S: the shim saw this process's GL.
    sl="$(grep -E '^gl_shim ' "$log" | tail -1)"
    [ -n "$sl" ] || fail "S $key: no gl_shim line (shim not loaded)"
    [[ "$sl" == *overflow=0* ]] || fail "S $key: shim slot overflow ($sl)"
    slots="$(sed -nE 's/.*proc_slots=([0-9]+).*/\1/p' <<< "$sl")"
    [ "$slots" -ge 50 ] || fail "S $key: Impeller's proc table bypassed the shim ($sl)"
    grep -q '^rn-impeller: record_gl ' "$log" || fail "R $key: no record_gl line"
    [ "$(field "$log" shim)" = 1 ] || fail "S $key: engine did not find rni_gl_shim_thread_calls"
    [ "$(field "$log" raster_calls)" -gt 0 ] || fail "S $key: raster_calls=0 (shim counts nothing)"
    # R: no GL in RECORD, and RECORD always ran with the context released.
    calls="$(field "$log" calls)"; frames="$(field "$log" frames)"; rel="$(field "$log" released)"
    [ "$calls" = 0 ] || fail "R $key: $calls GL calls inside RECORD"
    [ "$(field "$log" assert)" = 1 ] || fail "R $key: assert mode off"
    [ "$frames" -gt 0 ] && [ "$rel" = "$frames" ] || fail "R $key: context released for $rel of $frames RECORDs"
    [ "$(field "$log" starved)" = 0 ] || fail "R $key: name pool starved $(field "$log" starved)x"
    [ "$(field "$log" jobs_failed)" = 0 ] || fail "R $key: $(field "$log" jobs_failed) raster jobs failed"
    u="$(field "$log" uploads)"; o="$(field "$log" offscreens)"
    ups=$((ups + u)); offs=$((offs + o))
    # C: the GPU paths ran as raster jobs.
    case "$name" in
      images|sprites) [ "$u" -gt 0 ] || fail "C $key: no texture upload ran on the raster side" ;;
    esac
    # ss 1 = per-<Svg> offscreens only; ss 4 = the whole-tree offscreen (the
    # 1200x2100 grid is over the 8192 px bound at 4x and paints in place).
    if { [ "$ss" = 1 ] && [ "$name" = svg ]; } || { [ "$ss" = 4 ] && [ "$name" != grid ]; }; then
      [ "$o" -gt 0 ] || fail "C $key: no supersample offscreen ran on the raster side"
    fi
    runs=$((runs + 1))
    # P: pixels vs the pre-pass binary.
    [ -n "$REF" ] && render "$REF" "$line" "$ss" "$WORK/ref-$key" 0
    shots=("$key"); [ -s "$WORK/$key.first.ppm" ] && shots+=("$key.first")
    for s in "${shots[@]}"; do
      c="$(python3 tools/record_raster_check.py colors "$WORK/$s.ppm")" || fail "P $s is blank ($c)"
      if [ -n "$REF" ]; then
        out="$(python3 tools/record_raster_check.py diff "$WORK/$s.ppm" "$WORK/ref-$s.ppm" "$log")" \
          || fail "P pixels differ: $s $out"
        [ "$WRITE" = 1 ] && echo "$s $(python3 tools/record_raster_check.py hash "$WORK/ref-$s.ppm" "$WORK/ref-$key.log" | cut -d' ' -f1)" >> "$WORK/golden.new"
      else
        want="$(awk -v k="$s" '$1 == k {print $2}' "$GOLDEN")"
        [ -n "$want" ] || fail "P no golden for $s"
        read -r got m <<< "$(python3 tools/record_raster_check.py hash "$WORK/$s.ppm" "$log")"
        [ "$got" = "$want" ] || { cp "$WORK/$s.ppm" "/tmp/record-no-gl-$s.ppm"; fail "P pixels differ: $s sha256 $got vs pre-pass $want (kept /tmp/record-no-gl-$s.ppm)"; }
        out="sha256 match $m"
      fi
      compared=$((compared + 1))
      echo "   $s: calls=$calls frames=$frames released=$rel uploads=$u offscreens=$o raster_calls=$(field "$log" raster_calls) slots=$slots; $out, $c"
    done
  done
done
[ "$runs" -gt 0 ] || fail "setup: no case selected"
if [ "$WRITE" = 1 ]; then
  { echo "# FP-14 pre-pass (FP-13) renders, sha256 per capture, ref $(sha256sum "$REF" | cut -c1-12). Regenerate:"
    echo "# RNI_REF_BIN=<pre-change rn-impeller> RECORD_NO_GL_WRITE_GOLDEN=1 bash tools/ci-record-no-gl.sh"
    cat "$WORK/golden.new"; } > "$GOLDEN"
  echo "   wrote $GOLDEN"
fi
echo "RECORD_NO_GL PASS ($runs runs, $compared captures identical to the pre-pass binary; 0 GL calls in RECORD with no context current; raster jobs: $ups uploads, $offs offscreens)"
