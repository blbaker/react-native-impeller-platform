#!/usr/bin/env bash
# FP-16 GATE: bounded image IO pool + decode clamp (Flutter IO runner + ImageDecoderImpeller).
# Headless, node-free: prebuilt fixtures/fp16-image-io bundle + RNI_BIN, file:// images this
# script generates (tools/image_io_gate.py). Linux only (RSS and threads from /proc). Arms, in order:
#   big      8000x6000 PNG into a 200x200 box: peak RSS minus a 200x200-PNG control run < 64 MB,
#            one upload of at most 2x the box, decode = the expected cover-fit size
#   pixels   that decode vs an exact area-average reference of the PNG: max diff <= 2 levels
#   maxtex   RNI_TEST_MAX_TEXTURE_SIZE=128: decode and upload fit in 128; normal runs report the
#            GL max texture size the host queried
#   threads  200 distinct images, decodes held 20 ms each: peak concurrent decodes <= pool size
#            (min(4, cores/2)), peak OS threads (/proc sampling) <= a 1-image control + 2,
#            200 decodes, every tile painted its colour
#   cancel   40 images unmounted 30 ms after mount, decodes held 100 ms: >= 30 decodes skipped
#   dedup    one file in 10 boxes (one size bucket) while in flight: 1 decode, >= 9 shared
#   formats  14 PNG colour types / depths / tRNS cases with all 5 filter types, downscaled
#            through the streaming path: each within 2 levels of the area reference
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/fp16-image-io/prebuilt/fp16-image-io.bundle"
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
H="$ROOT/tools/image_io_gate.py"
fail() { echo "IMAGE_IO_GATE_FAIL: $*" >&2; exit 1; }
[ "$(uname -s)" = Linux ] || fail "linux only (reads /proc)"
[ -x "$BIN" ] || fail "no engine binary at $BIN"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
python3 -c 'import numpy, PIL' 2> /dev/null || fail "python3 with numpy + PIL is required"

WORK="$(mktemp -d)"
trap '[ -n "${KEEP_WORKDIR:-}" ] && echo "kept $WORK" >&2 || rm -rf "$WORK"' EXIT

# run <tag> <url> <w> <h> [ENV=V ...]: headless run; log in $WORK/<tag>.log, /proc peaks in <tag>.json
run() {
  local tag="$1" url="$2" w="$3" h="$4"; shift 4
  mkdir -p "$WORK/dump-$tag"
  set +e
  ( cd "$(dirname "$BIN")" && env RNI_IMAGE_LOG=1 RNI_TEST_IMAGE_DUMP="$WORK/dump-$tag" "$@" \
      python3 "$H" run "$WORK/$tag.json" -- "$BIN" --headless --probe-banner off --bundle "$BUNDLE" \
      --app-name Fp16ImageIo --width "$w" --height "$h" --scale 1 --supersample-rnsvg 0 \
      --initial-url "$url" --screenshot "$WORK/$tag.ppm" ) > "$WORK/$tag.log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag: engine exited $rc"; }
  grep -q '\[js-exception\]' "$WORK/$tag.log" && { grep -m3 '\[js-exception\]' "$WORK/$tag.log" >&2; fail "$tag: JS exception"; }
  return 0
}
sv() {  # tag key -> value from the image_io / rss_peak lines
  { grep -oE "(image_io .*|rss_peak_kb=[0-9]+)" "$WORK/$1.log" | grep -oE "(^| )$2=[0-9]+" | head -1 | cut -d= -f2; } || true
}
peak() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$WORK/$1.json" "$2"; }

echo "== generate images =="
mkdir -p "$WORK/big" "$WORK/many" "$WORK/fmt"
python3 "$H" gen-big "$WORK/big"
python3 "$H" gen-many "$WORK/many" 200
FMT="$(python3 "$H" gen-formats "$WORK/fmt")"

echo "== big: 8000x6000 PNG into a 200x200 box =="
run small "fp16://show?dir=$WORK/big&names=small.png&box=200&mode=cover" 400 300
run big "fp16://show?dir=$WORK/big&names=big.png&box=200&mode=cover" 400 300
# VmHWM sampled from /proc while the engine runs (the engine's own rss_peak_kb line is the same
# counter read at exit; take the larger, so a binary without that line is still measured)
rss() { local a b; a="$(peak "$1" rss_hwm_kb)"; b="$(sv "$1" rss_peak_kb)"; echo $(( a > ${b:-0} ? a : ${b:-0} )); }
RS="$(rss small)"; RB="$(rss big)"
[ "$RS" -gt 0 ] && [ "$RB" -gt 0 ] || fail "big: could not read peak RSS"
DELTA=$(( (RB - RS) / 1024 ))
echo "   peak RSS: control ${RS} kB, big ${RB} kB, delta ${DELTA} MB"
[ "$DELTA" -lt 64 ] || fail "big: peak RSS delta ${DELTA} MB >= 64 MB (decoded at full size?)"
grep -q "image_decode src=8000x6000 box=256x256 out=341x256" "$WORK/big.log" \
  || { grep image_decode "$WORK/big.log" >&2; fail "big: decode size is not the cover fit of the 256x256 bucket (341x256)"; }
UPS="$(grep -c 'image_upload ' "$WORK/big.log" || true)"
[ "$UPS" = 1 ] || fail "big: $UPS uploads, want 1"
read -r UW UH <<< "$(grep -oE 'image_upload w=[0-9]+ h=[0-9]+' "$WORK/big.log" | grep -oE '[0-9]+' | tr '\n' ' ')"
[ "$UW" -le 400 ] && [ "$UH" -le 400 ] || fail "big: uploaded ${UW}x${UH}, more than 2x the 200x200 box"
echo "   OK: delta ${DELTA} MB, decode 341x256, upload ${UW}x${UH}"

echo "== pixels: decode vs exact area reference =="
OUT="$(python3 "$H" cmp-big "$WORK/big" "$WORK/dump-big")" || fail "pixels: $OUT"
D="$(grep -oE '^maxdiff=[0-9]+' <<< "$OUT" | cut -d= -f2)"
[ -n "$D" ] && [ "$D" -le 2 ] || fail "pixels: downscaled image differs from the area reference by ${D:-?} levels ($OUT)"
echo "   OK: $OUT"

echo "== maxtex: clamp to the max texture size =="
MT="$(sv big max_texture)"
[ -n "$MT" ] && [ "$MT" -ge 2048 ] && [ $((MT & (MT - 1))) -eq 0 ] || fail "maxtex: host reported max_texture=${MT:-none}"
run clamp "fp16://show?dir=$WORK/big&names=big.png&box=200&mode=cover" 400 300 RNI_TEST_MAX_TEXTURE_SIZE=128
grep -q "max_texture=128" "$WORK/clamp.log" || fail "maxtex: override not applied"
read -r CW CH <<< "$(grep -oE 'image_upload w=[0-9]+ h=[0-9]+' "$WORK/clamp.log" | grep -oE '[0-9]+' | tr '\n' ' ')"
[ -n "${CW:-}" ] && [ "$CW" -le 128 ] && [ "$CH" -le 128 ] || fail "maxtex: uploaded ${CW:-?}x${CH:-?} with a 128 max texture size"
echo "   OK: GL max_texture=$MT; clamped upload ${CW}x${CH}"

echo "== threads: 200 distinct images =="
run one "fp16://show?dir=$WORK/many&count=1&box=30&cols=20&gap=2" 640 320 RNI_TEST_IMAGE_DECODE_DELAY_MS=20
run many "fp16://show?dir=$WORK/many&count=200&box=30&cols=20&gap=2" 640 320 RNI_TEST_IMAGE_DECODE_DELAY_MS=20
CORES="$(nproc)"; WANT=$(( CORES / 2 )); [ "$WANT" -gt 4 ] && WANT=4; [ "$WANT" -lt 1 ] && WANT=1
POOL="$(sv many pool)"; LIVE="$(sv many peak_live)"; DEC="$(sv many decodes)"; THR="$(sv many threads)"
[ "$POOL" = "$WANT" ] || fail "threads: pool=$POOL, want min(4, $CORES/2)=$WANT"
[ "$THR" -le "$POOL" ] || fail "threads: $THR pool threads started for a pool of $POOL"
[ "$LIVE" -le "$POOL" ] || fail "threads: peak live decode threads $LIVE > pool size $POOL"
[ "$DEC" = 200 ] || fail "threads: $DEC decodes for 200 images"
T1="$(peak one peak_threads)"; T200="$(peak many peak_threads)"; IO="$(peak many peak_io_threads)"
echo "   /proc peak threads: 1 image $T1, 200 images $T200 (rni-image-io $IO)"
[ "$IO" -le "$POOL" ] || fail "threads: $IO rni-image-io OS threads for a pool of $POOL"
[ "$T200" -le $(( T1 + 2 )) ] || fail "threads: peak OS threads $T200 with 200 images vs $T1 with 1 (a thread per image?)"
TILES="$(python3 "$H" tiles "$WORK/many.ppm" 200 30 2 20)"
[ "$TILES" = "tiles_bad=0 of 200" ] || fail "threads: $TILES painted the wrong colour"
echo "   OK: pool=$POOL peak_live=$LIVE decodes=$DEC, $TILES"

echo "== cancel: unmounted images skip their decode =="
run cancel "fp16://show?dir=$WORK/many&count=40&box=30&cols=20&gap=2&unmountMs=30" 640 320 RNI_TEST_IMAGE_DECODE_DELAY_MS=100
grep -q "FP16 unmounted" "$WORK/cancel.log" || fail "cancel: the fixture never unmounted"
CAN="$(sv cancel canceled)"; CDEC="$(sv cancel decodes)"
[ "${CAN:-0}" -ge 30 ] && [ "${CDEC:-99}" -le 10 ] || fail "cancel: canceled=${CAN:-?} decodes=${CDEC:-?} after unmounting 40 images (want >= 30 skipped)"
echo "   OK: canceled=$CAN decodes=$CDEC"

echo "== dedup: one file in 10 boxes of one size bucket decodes once =="
run dedup "fp16://show?dir=$WORK/many&names=$(printf 'img-7.png,%.0s' $(seq 9))img-7.png&box=30&cols=10&gap=2" 640 320 RNI_TEST_IMAGE_DECODE_DELAY_MS=100
DJ="$(sv dedup jobs)"; DD="$(sv dedup decodes)"; DS="$(sv dedup dedup)"
[ "${DD:-0}" = 1 ] && [ "${DS:-0}" -ge 9 ] || fail "dedup: decodes=${DD:-?} jobs=${DJ:-?} dedup=${DS:-?} for 10 in-flight requests of one URI + size"
echo "   OK: jobs=$DJ decodes=$DD dedup=$DS"

echo "== formats: streaming PNG rows, every colour type =="
run fmt "fp16://show?dir=$WORK/fmt&names=$FMT&box=100&cols=4&gap=2" 420 420
python3 "$H" cmp-formats "$WORK/fmt" "$WORK/dump-fmt" > "$WORK/fmt.txt"
sed 's/^/   /' "$WORK/fmt.txt"
N="$(grep -cE '192x128 maxdiff=[012]$' "$WORK/fmt.txt" || true)"
[ "$N" = 14 ] || fail "formats: $((14 - N)) of 14 PNG formats decode wrong ($(grep -vE '192x128 maxdiff=[012]$' "$WORK/fmt.txt" | head -1))"
echo "   OK: 14 formats within 2 levels"

echo "IMAGE_IO_GATE_PASS (rss_delta=${DELTA}MB upload=${UW}x${UH} pool=$POOL peak_live=$LIVE canceled=$CAN)"
