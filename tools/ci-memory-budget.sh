#!/usr/bin/env bash
# FP-33 GATE: byte-budgeted LRU for decoded images + textures, low-memory purge
# (model: Flutter's ImageCache, image_cache.dart: _checkCacheSize, clear() on memory pressure).
# Headless, node-free: prebuilt fixtures/fp33-memory-budget bundle + RNI_BIN, 500 distinct 256x256 PNGs
# this script generates (tools/memory_budget_gate.py). Linux only (rss_peak_kb = VmHWM). Arms, in order:
#   cycle    500 distinct images through 8-image groups with --image-cache-mb 6: all 500 decode, the cache
#            never holds more than 6 MB (peak and every frame's image_cache_bytes), it IS used (>= 5 MB),
#            evictions >= 400, the last group (most recently used) stays resident (reloads=0) and paints
#   default  the same without the flag: the cache stops at Flutter's 100 MiB
#   rss      peak RSS of the 500-image run is within 24 MB of the 250-image run (plateau), and an
#            unbounded control run (--image-cache-mb 100000) peaks >= 60 MB higher (the metric can see it)
#   purge    RNI_TEST_LOW_MEMORY_AT_FRAME=100 with floor 1 MB: the cache drops to the floor but keeps the
#            most recent entries, the visible images upload again and paint their own colour
#            and the painter holds exactly 8 textures at the end (textures_live=): the evicted bitmaps'
#            textures were released, not leaked next to their reloads
#   clear    same with the default floor 0: the cache is empty right after the signal, all 8 reload
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/fp33-memory-budget/prebuilt/fp33-memory-budget.bundle"
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
H="$ROOT/tools/memory_budget_gate.py"
fail() { echo "MEMORY_BUDGET_GATE_FAIL: $*" >&2; exit 1; }
[ "$(uname -s)" = Linux ] || fail "linux only (reads VmHWM)"
[ -x "$BIN" ] || fail "no engine binary at $BIN"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
python3 -c 'import numpy, PIL' 2> /dev/null || fail "python3 with numpy + PIL is required"

WORK="$(mktemp -d)"
trap '[ -n "${KEEP_WORKDIR:-}" ] && echo "kept $WORK" >&2 || rm -rf "$WORK"' EXIT
MB=1048576

# run <tag> <count> [ENV=V ...] -- [engine args]: log in $WORK/<tag>.log, frame timings in <tag>.json
run() {
  local tag="$1" count="$2"; shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  set +e
  ( cd "$(dirname "$BIN")" && env RNI_IMAGE_LOG=1 ${envs[@]+"${envs[@]}"} "$BIN" --headless --probe-banner off \
      --bundle "$BUNDLE" --app-name Fp33MemoryBudget --width 1536 --height 192 --scale 1 --supersample-rnsvg 0 \
      --initial-url "fp33://cycle?dir=$WORK/img&count=$count&per=8&box=192" --frames 150 \
      --frame-timings-out "$WORK/$tag.json" --screenshot "$WORK/$tag.ppm" "$@" ) > "$WORK/$tag.log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag: engine exited $rc"; }
  grep -q '\[js-exception\]' "$WORK/$tag.log" && { grep -m3 '\[js-exception\]' "$WORK/$tag.log" >&2; fail "$tag: JS exception"; }
  grep -q "FP33 cycled" "$WORK/$tag.log" || fail "$tag: the fixture never finished cycling its $count images"
  return 0
}
sv() {  # tag line-prefix key -> value of key= on the first line containing the prefix
  { grep -m1 "$2" "$WORK/$1.log" | grep -oE "(^| )$3=-?[0-9]+" | head -1 | cut -d= -f2; } || true
}
need() { [ -n "$2" ] || fail "$1: no value in the log (stats line missing)"; }
frames_max() {  # tag -> max image_cache_bytes over the frame records, and the record count
  python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))["frames"]; print(max(x["image_cache_bytes"] for x in f), len(f))' "$WORK/$1.json"
}
tiles() { python3 "$H" tiles "$WORK/$1.ppm" "$2" 8 192; }

echo "== generate 500 images =="
mkdir -p "$WORK/img"
python3 "$H" gen "$WORK/img" 500 256

echo "== cycle: 500 distinct images, 6 MB budget =="
run cycle 500 -- --image-cache-mb 6
DEC="$(sv cycle image_io decodes)"; PEAK="$(sv cycle "image_cache bytes" peak)"; EVI="$(sv cycle "image_cache bytes" evictions)"
REL="$(sv cycle "image_cache bytes" reloads)"
need cycle "$DEC"; need cycle "$PEAK"; need cycle "$EVI"; need cycle "$REL"
[ "$DEC" -ge 500 ] || fail "cycle: only $DEC of 500 images were decoded"
[ "$PEAK" -le $((6 * MB)) ] || fail "cycle: cache peak $PEAK bytes exceeds the 6 MB budget"
[ "$PEAK" -ge $((5 * MB)) ] || fail "cycle: cache peak $PEAK bytes: the cache is not holding decoded images"
[ "$EVI" -ge 400 ] || fail "cycle: evictions=$EVI, expected >= 400 for 500 images in a 24-image cache"
read -r FMAX FN < <(frames_max cycle)
[ "$FN" -ge 100 ] || fail "cycle: only $FN frame records carry image_cache_bytes"
[ "$FMAX" -le $((6 * MB)) ] || fail "cycle: a frame reported image_cache_bytes=$FMAX over the budget"
[ "$FMAX" -ge $((5 * MB)) ] || fail "cycle: frames report image_cache_bytes max $FMAX, expected the cache to be full"
[ "$REL" -eq 0 ] || fail "cycle: reloads=$REL, the most recently used images were evicted (LRU order)"
T="$(tiles cycle 492)"
[ "$T" = "tiles_bad=0 of 8" ] || fail "cycle: $T painted the wrong colour"

echo "== default budget =="
run default 500 --
DPEAK="$(sv default "image_cache bytes" peak)"; DEVI="$(sv default "image_cache bytes" evictions)"
need default "$DPEAK"; need default "$DEVI"
[ "$DPEAK" -le $((100 * MB)) ] || fail "default: cache peak $DPEAK bytes exceeds Flutter's 100 MiB"
[ "$DPEAK" -ge $((90 * MB)) ] || fail "default: cache peak $DPEAK bytes, expected it to fill toward 100 MiB"
[ "$DEVI" -ge 50 ] || fail "default: evictions=$DEVI, expected >= 50"

echo "== rss: plateau + unbounded control =="
run half 250 -- --image-cache-mb 6
run big 500 -- --image-cache-mb 100000
R250="$(sv half rss_peak rss_peak_kb)"; R500="$(sv cycle rss_peak rss_peak_kb)"; RBIG="$(sv big rss_peak rss_peak_kb)"
need rss "$R250"; need rss "$R500"; need rss "$RBIG"
DIFF=$(( (R500 - R250) / 1024 )); CTRL=$(( (RBIG - R500) / 1024 ))
[ "$DIFF" -le 24 ] || fail "rss: peak RSS grew ${DIFF} MB from 250 to 500 images, expected a plateau (<= 24 MB)"
[ "$CTRL" -ge 60 ] || fail "rss: the unbounded control peaks only ${CTRL} MB above the bounded run (>= 60 MB wanted)"

purge_arm() {  # tag floor_mb expect: 500-free run, 64 images, signal at frame 100
  local tag="$1" floor="$2"
  run "$tag" 64 RNI_TEST_LOW_MEMORY_AT_FRAME=100 RNI_IMAGE_CACHE_FLOOR_MB="$floor" --
  local line; line="$(grep -m1 'low_memory source=test' "$WORK/$tag.log" || true)"
  [ -n "$line" ] || fail "$tag: no low_memory line, the signal never arrived"
  BEFORE="$(echo "$line" | grep -oE 'image_cache_bytes_before=[0-9]+' | cut -d= -f2)"
  AFTER="$(echo "$line" | grep -oE 'image_cache_bytes_after=[0-9]+' | cut -d= -f2)"
  PURGES="$(sv "$tag" "image_cache bytes" purges)"; REL="$(sv "$tag" "image_cache bytes" reloads)"
  UPS="$(awk '/low_memory source=/{f=1} f && /image_upload/{n++} END{print n+0}' "$WORK/$tag.log")"
  need "$tag" "$BEFORE"; need "$tag" "$AFTER"; need "$tag" "$REL"
  [ "$BEFORE" -ge $((8 * MB)) ] || fail "$tag: only $BEFORE bytes cached before the signal"
  [ "$PURGES" -eq 1 ] || fail "$tag: purges=$PURGES, expected exactly 1"
}
purge_tail() {  # tag: after the arm's own checks, the textures and the pixels
  local tag="$1" tex t
  tex="$(sv "$tag" "image_cache bytes" textures_live)"; need "$tag" "$tex"
  [ "$tex" -eq 8 ] || fail "$tag: textures_live=$tex, expected the 8 visible images (evicted textures leaked)"
  t="$(tiles "$tag" 56)"
  [ "$t" = "tiles_bad=0 of 8" ] || fail "$tag: $t painted the wrong colour after the purge"
}

echo "== purge: floor 1 MB =="
purge_arm purge 1
[ "$AFTER" -le $((1 * MB)) ] || fail "purge: cache holds $AFTER bytes after the signal, floor is $MB"
[ "$AFTER" -gt 0 ] || fail "purge: cache emptied, the floor must keep the most recent entries"
[ "$REL" -ge 4 ] && [ "$UPS" -ge 4 ] || fail "purge: reloads=$REL uploads_after=$UPS, the evicted visible images did not repaint"
read -r _ PN < <(frames_max purge)
LAST="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["frames"][-1]["image_cache_bytes"])' "$WORK/purge.json")"
[ "$LAST" -gt 0 ] || fail "purge: the last frame reports image_cache_bytes=0, the cache never refilled"
purge_tail purge

echo "== clear: default floor 0 =="
purge_arm clear 0
[ "$AFTER" -eq 0 ] || fail "clear: cache holds $AFTER bytes right after the signal, expected 0 (Flutter clear())"
[ "$REL" -ge 8 ] && [ "$UPS" -ge 8 ] || fail "clear: reloads=$REL uploads_after=$UPS, expected all 8 visible images to reload"
purge_tail clear

echo "MEMORY_BUDGET_GATE_PASS (peak=${PEAK} default_peak=${DPEAK} evictions=${EVI} rss250=${R250}KB rss500=${R500}KB unbounded=${RBIG}KB purge_after=${AFTER})"
