#!/usr/bin/env bash
# FP-17 GATE: image textures upload on the IO thread, not the raster thread (Flutter's IO runner
# resource context + ImageDecoderImpeller upload-before-result). Windowed (raster thread, FP-15),
# node-free: prebuilt fixtures/fp17-image-upload bundle + RNI_BIN, PNGs this script generates.
#   A  timing: 30 images of 1448x1448 (8 MB uploads) arrive one per 150 ms while a native-driver
#      animation runs (--vsync software, 600 frames). Control = the same run with the images
#      decoded, uploaded and painted BEFORE the window (fixture preload=1), so the window has the
#      same frames and draws but no decode and no upload. 7 interleaved reps per arm, p99 of the
#      frames in a fixed window per rep: median(arrive) <= 1.2 x median(control). Then in every
#      arrive rep: io_upload uploads=31 taken=31 failed=0, every image_upload line thread=io on a thread
#      that is not the raster thread, and every tile paints its image's colour at the end.
#   B  fence: RNI_TEST_IO_UPLOAD_DELAY_MS=120 holds each transfer open with poison (magenta)
#      storage; RNI_TEST_POISON_PROBE=1 reads back every present: 0 poisoned presents, all tiles
#      correct at the end.
#   C  --io-upload off: the raster-side path still paints every tile correctly.
# llvmpipe stands in for the GPU and renders on the CPU in this process, which couples raster
# time to CPU work a GPU never sees. Every arm runs with the same two settings that remove that
# coupling: (1) glibc mmap/trim thresholds raised: large allocations on any thread (decode
# buffers, texture storage) otherwise contend with llvmpipe's per-frame mmap'd scene buffers on
# the process mmap lock; (2) LP_NUM_THREADS=2: with one worker per core (22 here) a frame waits
# for its slowest worker, so any busy core (decode pool, IO thread, another job) stretches it.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/fp17-image-upload/prebuilt/fp17-image-upload.bundle"
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
H="$ROOT/tools/image_upload_gate.py"
fail() { echo "IMAGE_UPLOAD_FAIL: $*" >&2; exit 1; }
[ "$(uname -s)" = Linux ] || fail "linux only (xvfb, llvmpipe timings)"
[ -x "$BIN" ] || fail "no engine binary at $BIN"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
python3 -c 'import PIL' 2> /dev/null || fail "python3 with PIL is required"
echo "engine: $BIN ($(sha256sum "$BIN" | cut -c1-12))"

WORK="$(mktemp -d)"
trap '[ -n "${KEEP_WORKDIR:-}" ] && echo "kept $WORK" >&2 || rm -rf "$WORK"' EXIT
python3 "$H" gen "$WORK" 30 1448

# run <tag> <frames> <query> [engine args] -- [ENV=V ...]
run() {
  local tag="$1" frames="$2" q="$3"; shift 3
  local args=() envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  envs=("$@")
  local rc=0
  ( cd "$(dirname "$BIN")" && env RNI_IMAGE_LOG=1 MALLOC_MMAP_THRESHOLD_=268435456 \
      MALLOC_TRIM_THRESHOLD_=1073741824 LP_NUM_THREADS=2 "${envs[@]}" timeout 180 \
      xvfb-run -a -f "$WORK/xvfb-$tag.auth" -s "-screen 0 1280x1024x24" \
      "$BIN" --window --scale 1 --app-name Fp17ImageUpload --bundle "$BUNDLE" --width 600 \
      --height 560 --supersample-rnsvg 0 --vsync software --frames "$frames" "${args[@]}" \
      --initial-url "fp17://run?dir=$WORK&box=1448&startMs=1200&$q" \
      --frame-timings-out "$WORK/$tag.json" --screenshot "$WORK/$tag.ppm" \
      --screenshot-after-frames $((frames - 10)) ) > "$WORK/$tag.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag: engine exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$WORK/$tag.log" || fail "$tag: nothing mounted"
  grep -q '\[js-exception\]' "$WORK/$tag.log" && fail "$tag: JS exception"
  return 0
}
field() { grep -oE "^rn-impeller: $2 .*" "$WORK/$1.log" | grep -oE "(^| )$3=[^ ]+" | head -1 | cut -d= -f2; }
tiles() { python3 "$H" tiles "$WORK/$1.ppm" "$WORK" "$2" || fail "$1: $3"; }

echo "== A: 30 x 8 MB uploads during an animation vs the preloaded control (7 reps each) =="
# Timing on a shared 22-core box: interleave the arms, take each arm's MEDIAN per-rep p99 (a rep
# another job disturbs moves one sample, not the verdict).
for r in 1 2 3 4 5 6 7; do
  run "arrive$r" 600 "count=30&intervalMs=150"
  run "control$r" 600 "count=30&intervalMs=150&preload=1"
done
# window: first tile mount (startMs) .. 6.5 s, i.e. the 4.5 s of arrivals + their decodes
med() {  # arm -> median of the per-rep raster p99 (us); also prints each rep
  local v=() r x
  for r in 1 2 3 4 5 6 7; do
    x="$(python3 "$H" p99 1250000 6500000 "$WORK/$1$r.json")"
    [ "$(grep -oE 'n=[0-9]+' <<< "$x" | cut -d= -f2)" -ge 200 ] || fail "A: $1$r has too few frames in the window ($x)"
    v+=("$(grep -oE 'p99=[0-9]+' <<< "$x" | cut -d= -f2)")
  done
  echo "$(printf '%s\n' "${v[@]}" | sort -n | sed -n 4p) (reps: ${v[*]})"
}
AM="$(med arrive)"; CM="$(med control)"
A99="${AM%% *}"; C99="${CM%% *}"
echo "   raster_p99 arrive: $AM; control: $CM"
[ -n "$A99" ] && [ -n "$C99" ] && [ "$C99" -gt 0 ] || fail "A: no timing data for an arm"
python3 -c "import sys; a,c=int(sys.argv[1]),int(sys.argv[2]); sys.exit(0 if a <= 1.2*c else 1)" "$A99" "$C99" \
  || fail "A: raster_p99 ${A99} us > 1.2 x control ${C99} us: upload time is in the raster frame"
for r in 1 2 3 4 5 6 7; do
  t="arrive$r"
  RT="$(field "$t" raster_thread raster_tid)"
  [ "$(field "$t" raster_thread threaded)" = 1 ] || fail "$t: no raster thread"
  for k in uploads taken; do
    [ "$(field "$t" io_upload "$k")" = 31 ] || fail "$t: io_upload $k=$(field "$t" io_upload "$k"), want 31 (30 + warm)"
  done
  [ "$(field "$t" io_upload failed)" = 0 ] || fail "$t: io_upload failed=$(field "$t" io_upload failed)"
  NUP="$(grep -c 'image_upload ' "$WORK/$t.log" || true)"
  NIO="$(grep -cE "image_upload .* thread=io tid=[0-9]+" "$WORK/$t.log" || true)"
  [ "$NUP" = 31 ] && [ "$NIO" = 31 ] || fail "$t: $NUP uploads, $NIO on the IO thread (want 31 / 31)"
  grep -qE "image_upload .* thread=io tid=$RT " "$WORK/$t.log" && fail "$t: an IO upload ran on the raster thread ($RT)"
  tiles "$t" 30 "an image did not paint its colour"
done
echo "   OK: raster_p99 ${A99} us <= 1.2 x ${C99} us; 7 x 31 uploads on the IO thread; 7 x 30 tiles correct"

echo "== B: transfers held open 120 ms with poison storage: nothing shown before its fence =="
run fence 360 "count=8&intervalMs=150" -- RNI_TEST_IO_UPLOAD_DELAY_MS=120 RNI_TEST_POISON_PROBE=1
P="$(field fence poison_probe presents)"; PZ="$(field fence poison_probe poisoned)"
[ -n "$P" ] && [ "$P" -ge 300 ] || fail "B: poison probe read back ${P:-no} presents"
[ "$(field fence io_upload delay_ms)" = 120 ] || fail "B: the transfer delay hook is not active"
[ "$PZ" = 0 ] || fail "B: $PZ presents showed an image before its upload fence (first=$(field fence poison_probe first), max_px=$(field fence poison_probe max_px))"
tiles fence 8 "an image did not paint its colour after a delayed transfer"
echo "   OK: $P presents read back, 0 poisoned, 8 tiles correct"

echo "== C: --io-upload off still paints every image (raster-side fallback) =="
run off 300 "count=8&intervalMs=50" --io-upload off
[ "$(field off io_upload enabled)" = 0 ] || fail "C: --io-upload off did not disable the IO thread"
[ "$(grep -c 'thread=raster' "$WORK/off.log" || true)" -ge 9 ] || fail "C: images did not upload on the raster side"
tiles off 8 "an image did not paint its colour with --io-upload off"
echo "   OK: 9 raster-side uploads, 8 tiles correct"

echo "IMAGE_UPLOAD_PASS (raster_p99 ${A99}/${C99} us arrive/control, 217 IO uploads, 0 poisoned presents)"
