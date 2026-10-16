#!/usr/bin/env bash
# FP-20 BACKEND-AGNOSTIC TEXTURES AND OFFSCREENS (model: image_decoder_impeller.cc:730-737
# uploads per backend; interop backend/gles holds the GL-only entry points; Metal/Vulkan
# get MSAA from the surface wrap, backend/metal/surface_mtl.mm).
#   B  --backend: gles runs and reports `gpu_backend context=gles policy=gles
#      uploader=gl_name supersample=gl`; metal and vulkan are refused (not available
#      yet); an unknown value is refused.
#   G  grep: no GL symbol outside the GL backend files (tools/gl_symbol_scan.py:
#      basename with GL/Gl/Gles; comments and strings stripped). Self-test first.
#   P  pixels: core fixtures (style grid, text, svg, world sprites, world nearest,
#      images headless; world sprites windowed) x supersample {0,1,4} are identical
#      to the pre-pass binary: RNI_REF_BIN=<old rn-impeller> diffs per pixel, else
#      tools/backend-agnostic-golden.txt (sha256 of the pre-pass renders, linux x64
#      llvmpipe; BACKEND_AGNOSTIC_WRITE_GOLDEN=1 + RNI_REF_BIN rewrites it).
#   M  backend policy: RNI_TEST_BACKEND_POLICY=metal|vulkan paints with that
#      backend's rules on the headless GL context. At --supersample-rnsvg 4 every
#      texture must be Impeller-owned (gpu_textures gl_names=0, contents > 0 where
#      the fixture has textures), no supersample offscreen may run
#      (offscreen_targets=0, record_gl offscreens=0) and the pixels must equal the
#      GL render at supersample 0 (which differs from GL at 4 on svg and sprites).
# Node-free (committed prebuilt bundles). Engine: RNI_BIN or the staged linux package.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail() { echo "BACKEND_AGNOSTIC FAIL $*"; exit 1; }

BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$BIN" ] || fail "setup: no engine at $BIN"
REF="${RNI_REF_BIN:-}"
GOLDEN="$ROOT/tools/backend-agnostic-golden.txt"
WRITE="${BACKEND_AGNOSTIC_WRITE_GOLDEN:-0}"
if [ "$WRITE" = 1 ] && [ -z "$REF" ]; then fail "setup: BACKEND_AGNOSTIC_WRITE_GOLDEN needs RNI_REF_BIN"; fi
[ -n "$REF" ] || [ -s "$GOLDEN" ] || fail "setup: no $GOLDEN"
echo "engine: $BIN ($(sha256sum "$BIN" | cut -c1-12))${REF:+ ref: $REF}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-backend-agnostic.XXXX")"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "kept $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

FX="$ROOT/fixtures"
FONTS="$FX/eng22-font-family/fonts"
SPRITES="eng10-world-sprites/prebuilt/eng10-world-sprites.bundle|Eng10Sprites"
# name | mode | bundle | app | args
CASES=(
  "grid|h|style-audit/prebuilt/style-audit.bundle|probe|--width 1200 --height 2100 --initial-url probe://grid"
  "text|h|eng22-font-family/prebuilt/eng22-font-family.bundle|Eng22FontFamily|--width 400 --height 300 --font-dir $FONTS"
  "svg|h|eng-supersample/prebuilt/eng-supersample.bundle|EngSupersample|"
  "sprites|h|$SPRITES|--width 320 --height 240"
  "nearest|h|eng21-world-nearest/prebuilt/eng21-world-nearest.bundle|Eng21Nearest|--width 320 --height 240"
  "images|h|image-net/prebuilt/image-net.bundle|probe|--width 440 --height 130 --scale 1"
  "sprites-window|w|$SPRITES|--width 320 --height 240 --frames 20 --screenshot-after-frames 10"
)
# Policy arm: cases with textures (contents uploads) and/or supersample hooks.
POLICY_CASES="sprites nearest images svg grid"
TEXTURED="sprites nearest images"
SS_VISIBLE="svg sprites"  # GL at ss 4 differs from ss 0 here

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
. tools/lib/own-port.sh
rni_own_port 18931 "$WORK/server.out" python3 "$WORK/server.py" \
  || fail "setup: image server could not own 127.0.0.1:18931 for 2 min"
SERVER_PID="$OWN_PORT_PID"

case_line() { local c; for c in "${CASES[@]}"; do [ "${c%%|*}" = "$1" ] && { echo "$c"; return; }; done; fail "setup: no case $1"; }

render() {  # bin case-line ss out-prefix policy(''|metal|vulkan) [extra args...]
  local bin="$1" line="$2" ss="$3" out="$4" pol="$5"; shift 5
  local name mode bundle app args rc=0
  IFS='|' read -r name mode bundle app args <<< "$line"
  # shellcheck disable=SC2206
  local a=(--bundle "$FX/$bundle" --app-name "$app" --probe-banner off --supersample-rnsvg "$ss" $args "$@")
  local pre=(env)
  [ -n "$pol" ] && pre=(env RNI_TEST_BACKEND_POLICY="$pol")
  if [ "$mode" = h ]; then
    ( cd "$(dirname "$bin")" && timeout 300 "${pre[@]}" "$bin" --headless "${a[@]}" --screenshot "$out.ppm" ) \
      > "$out.log" 2>&1 || rc=$?
  else
    ( cd "$(dirname "$bin")" && timeout 300 xvfb-run -a -f "$WORK/xvfb.auth" -s "-screen 0 1280x1024x24" \
        "${pre[@]}" "$bin" --window --scale 1 "${a[@]}" --screenshot "$out.ppm" ) > "$out.log" 2>&1 || rc=$?
  fi
  [ "$rc" -eq 0 ] || { tail -12 "$out.log"; fail "$name ss=$ss${pol:+ policy=$pol}: engine exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$out.log" || fail "$name ss=$ss: nothing mounted"
  [ -s "$out.ppm" ] || fail "$name ss=$ss: no screenshot"
}
gfield() { sed -nE "s/^rn-impeller: gpu_textures .*\\b$2=([0-9]+).*/\\1/p" "$1" | tail -1; }
rfield() { sed -nE "s/^rn-impeller: record_gl .*\\b$2=([0-9]+).*/\\1/p" "$1" | tail -1; }
mhash() { python3 tools/record_raster_check.py hash "$1.ppm" "$1.log" | cut -d' ' -f1; }

# ---- B: the --backend flag. ----
LINE="$(case_line svg)"
render "$BIN" "$LINE" 0 "$WORK/b-gles" "" --backend gles
grep -q '^rn-impeller: gpu_backend context=gles policy=gles uploader=gl_name supersample=gl$' "$WORK/b-gles.log" \
  || fail "B --backend gles: $(grep -m1 gpu_backend "$WORK/b-gles.log" || echo 'no gpu_backend line')"
for b in metal vulkan bogus; do
  rc=0
  ( cd "$(dirname "$BIN")" && timeout 60 "$BIN" --headless --bundle "$FX/eng-supersample/prebuilt/eng-supersample.bundle" \
      --app-name EngSupersample --backend "$b" --screenshot "$WORK/b-$b.ppm" ) > "$WORK/b-$b.log" 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "B --backend $b was accepted (exit $rc, want 2): $(grep -m1 gpu_backend "$WORK/b-$b.log")"
  if [ "$b" = bogus ]; then want='--backend wants gles\|metal\|vulkan'; else want="--backend $b is (not available yet|darwin-only)"; fi  # FP-21: metal runs windowed on darwin
  grep -qE -- "$want" "$WORK/b-$b.log" || fail "B --backend $b: no refusal line ($(tail -1 "$WORK/b-$b.log"))"
done
echo "   B: --backend gles runs (gl_name uploader, gl supersample); metal/vulkan/bogus refused with exit 2"

# ---- G: no GL symbol above the GL backend. ----
python3 tools/gl_symbol_scan.py self-test > "$WORK/scan-self.log" 2>&1 || { cat "$WORK/scan-self.log"; fail "G scanner self-test"; }
if ! python3 tools/gl_symbol_scan.py scan "$ROOT" > "$WORK/scan.log" 2>&1; then
  head -5 "$WORK/scan.log"; fail "G GL symbol outside the GL backend files: $(head -1 "$WORK/scan.log")"
fi
summary="$(tail -1 "$WORK/scan.log")"
gl_lines="$(sed -nE 's/.*gl_backend_symbol_lines=([0-9]+).*/\1/p' <<< "$summary")"
[ "${gl_lines:-0}" -ge 100 ] || fail "G scanner sees no GL even in the GL backend ($summary)"
echo "   G: $summary"

# ---- P: pixels vs the pre-pass binary. ----
[ "$WRITE" = 1 ] && : > "$WORK/golden.new"
compared=0
for ss in 0 1 4; do
  for line in "${CASES[@]}"; do
    name="${line%%|*}"; key="$name-ss$ss"
    render "$BIN" "$line" "$ss" "$WORK/$key" ""
    c="$(python3 tools/record_raster_check.py colors "$WORK/$key.ppm")" || fail "P $key is blank ($c)"
    if [ -n "$REF" ]; then
      render "$REF" "$line" "$ss" "$WORK/ref-$key" ""
      out="$(python3 tools/record_raster_check.py diff "$WORK/$key.ppm" "$WORK/ref-$key.ppm" "$WORK/$key.log")" \
        || fail "P pixels differ from the pre-pass binary: $key $out"
      [ "$WRITE" = 1 ] && echo "$key $(mhash "$WORK/ref-$key")" >> "$WORK/golden.new"
    else
      want="$(awk -v k="$key" '$1 == k {print $2}' "$GOLDEN")"
      [ -n "$want" ] || fail "P no golden for $key"
      got="$(mhash "$WORK/$key")"
      [ "$got" = "$want" ] || { cp "$WORK/$key.ppm" "/tmp/backend-agnostic-$key.ppm"; fail "P pixels differ from the pre-pass binary: $key sha256 $got vs $want (kept /tmp/backend-agnostic-$key.ppm)"; }
      out="sha256 match"
    fi
    compared=$((compared + 1))
    echo "   P $key: $out, $c, gl_names=$(gfield "$WORK/$key.log" gl_names) offscreen_targets=$(gfield "$WORK/$key.log" offscreen_targets)"
  done
done
if [ "$WRITE" = 1 ]; then
  { echo "# FP-20 pre-pass renders, masked sha256 per capture, ref $(sha256sum "$REF" | cut -c1-12). Regenerate:"
    echo "# RNI_REF_BIN=<pre-change rn-impeller> BACKEND_AGNOSTIC_WRITE_GOLDEN=1 bash tools/ci-backend-agnostic.sh"
    cat "$WORK/golden.new"; } > "$GOLDEN"
  echo "   wrote $GOLDEN"
fi

# ---- M: other backends' rules on the GL context. ----
policies=0
for pol in metal vulkan; do
  for name in $POLICY_CASES; do
    [ "$pol" = vulkan ] && [[ " sprites svg " != *" $name "* ]] && continue
    key="$name-$pol"
    render "$BIN" "$(case_line "$name")" 4 "$WORK/$key" "$pol"
    log="$WORK/$key.log"
    gl="$(gfield "$log" gl_names)"; ct="$(gfield "$log" contents)"; tg="$(gfield "$log" offscreen_targets)"
    [ -n "$gl" ] || fail "M $key: no gpu_textures line"
    [ "$gl" = 0 ] || fail "M world/texture path $key: $gl textures adopted GL names under backend=$pol (want Impeller-owned uploads)"
    if [[ " $TEXTURED " == *" $name "* ]]; then
      [ "$ct" -gt 0 ] || fail "M $key: no Impeller-owned upload ran (contents=0) on a textured fixture"
    fi
    [ "$tg" = 0 ] && [ "$(rfield "$log" offscreens)" = 0 ] \
      || fail "M supersample $key: the supersample hook ran under backend=$pol (offscreen_targets=$tg offscreens=$(rfield "$log" offscreens))"
    base="$(mhash "$WORK/$name-ss0")"; got="$(mhash "$WORK/$key")"
    if [[ " $SS_VISIBLE " == *" $name "* ]]; then
      [ "$(mhash "$WORK/$name-ss4")" != "$base" ] || fail "M setup $name: GL ss4 == ss0, the arm cannot see a supersample run"
    fi
    [ "$got" = "$base" ] || fail "M supersample/pixels $key: backend=$pol at ss 4 differs from GL at ss 0 ($(python3 tools/record_raster_check.py diff "$WORK/$key.ppm" "$WORK/$name-ss0.ppm" "$log" || true))"
    # Read-back counters and pixels first (above); the configuration line last.
    want="rn-impeller: gpu_backend context=gles policy=$pol uploader=contents supersample=none"
    grep -qx "$want" "$log" || fail "M $key: $(grep -m1 gpu_backend "$log" || echo 'no gpu_backend line') (want '$want')"
    policies=$((policies + 1))
    echo "   M $key: uploader=contents contents=$ct gl_names=0 supersample=none, pixels == GL ss0"
  done
done
echo "BACKEND_AGNOSTIC PASS (backend flag ok; $summary; $compared captures identical to the pre-pass binary; $policies metal/vulkan-policy renders with 0 GL names, 0 supersample offscreens, pixels == GL ss0)"
