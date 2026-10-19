#!/usr/bin/env bash
# Paragraph layout cache GATE (Jim v5 chat-loop report, 2026-10-19).
#
# fixtures/chat-loop: 300 <Text> paragraphs of ~200 chars under a 3-dot
# typing indicator (Animated.loop on opacity, 1.2 s). Before the cache, every
# frame re-shaped every paragraph, so an opacity tick on one dot cost a whole
# transcript of HarfBuzz work and the process sat at ~100% CPU.
#
#   A  cost, native driver (headless, frame-counted). Over --frames 120 each
#      paragraph is shaped once: misses <= 320 (300 paragraphs + slack) and
#      hits >= 300*100. Control: the SAME binary with RNI_PARAGRAPH_CACHE=0
#      must count misses >= 300*120, so the counter can tell the two apart.
#   B  cost, JS driver (windowed; the path Jim's own TypingDot takes, one
#      setNativeProps commit per dot per frame): >= 60 frames painted with
#      misses <= 320.
#   C  correctness (windowed). ChatLoopMutate changes text, run colour, own
#      opacity, layout width, font size and text alignment once each, then
#      holds. The cached final frame must be byte-identical to the uncached
#      one, and two uncached runs must agree (so a difference is the cache,
#      not run-to-run noise).
#
# Node-free: committed bundle + RNI_BIN. linux runs the windowed arms under
# xvfb; darwin uses the real window server.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/chat-loop/prebuilt/chat-loop.bundle"
fail() { echo "PARA_CACHE_FAIL: $*" >&2; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
. tools/lib/host-window.sh
[ "$(rni_host)" != other ] || fail "linux (xvfb) or darwin only"
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
else
  bash tools/engine-build.sh > "${TMPDIR:-/tmp}/ci-para-build.log" 2>&1 \
    || { tail -20 "${TMPDIR:-/tmp}/ci-para-build.log" >&2; fail "engine build failed"; }
  BIN="$ROOT/packages-engine/engine-$(rni_host)-$( [ "$(uname -m)" = arm64 ] && echo arm64 || echo x64)/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
echo "engine: $BIN ($(shasum -a 256 "$BIN" | cut -c1-12)) host=$(rni_host)"

WORK="$(mktemp -d)"
cleanup() { [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

field() {  # log key -> value of key= on the paragraph_cache line
  sed -n "s/^rn-impeller: paragraph_cache .*[ ]$2=\([0-9]*\).*/\1/p" "$1" | tail -1
}
need_line() {  # log ERE what
  grep -qE "$2" "$1" || { tail -15 "$1" >&2; fail "$3"; }
}

headless() {  # tag app frames cache(0|1)
  local tag="$1" app="$2" frames="$3" rc=0
  ( export RNI_PARAGRAPH_CACHE="$4"; cd "$(dirname "$BIN")" && timeout 240 "$BIN" --headless \
      --width 800 --height 600 --bundle "$BUNDLE" --app-name "$app" --probe-banner off \
      --supersample-rnsvg 0 --frames "$frames" ) > "$WORK/$tag.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag exited $rc"; }
  need_line "$WORK/$tag.log" '^rn-impeller: scene_nodes=[1-9]' "$tag: nothing mounted"
}

windowed() {  # tag app w h runsec cache(0|1) [extra engine args...]
  local tag="$1" app="$2" w="$3" h="$4" sec="$5" cache="$6" rc=0; shift 6
  ( export RNI_PARAGRAPH_CACHE="$cache"; cd "$(dirname "$BIN")" && rni_xrun "$WORK/xvfb.auth" \
      timeout 120 "$BIN" --window --scale 1 --width "$w" --height "$h" --bundle "$BUNDLE" \
      --app-name "$app" --probe-banner off --supersample-rnsvg 0 --idle-skip \
      --idle-run-sec "$sec" "$@" ) > "$WORK/$tag.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag exited $rc"; }
  need_line "$WORK/$tag.log" 'RN_IMPELLER_WINDOW_OK' "$tag: window run did not finish OK"
}

echo "== A: native driver, headless --frames 120 =="
headless a-cached ChatLoop 120 1
headless a-uncached ChatLoop 120 0
for t in a-cached a-uncached; do
  need_line "$WORK/$t.log" 'chatloop dots=3 native=1' "$t: the dots did not run on the native driver"
  need_line "$WORK/$t.log" '^rn-impeller: nativeanimated_ticks=120$' "$t: native animation did not tick every frame"
  need_line "$WORK/$t.log" '^rn-impeller: paragraph_cache ' "$t: no paragraph_cache line (engine predates the cache)"
done
AH=$(field "$WORK/a-cached.log" hits); AM=$(field "$WORK/a-cached.log" misses)
UM=$(field "$WORK/a-uncached.log" misses)
echo "   cached: hits=$AH misses=$AM | uncached: misses=$UM"
echo "   build: cached $(grep -o 'build_p50=[0-9]*' "$WORK/a-cached.log" | tail -1) uncached $(grep -o 'build_p50=[0-9]*' "$WORK/a-uncached.log" | tail -1) (us, informational)"
[ "${UM:-0}" -ge $((300 * 120)) ] || fail "A control: uncached misses=$UM < 36000 -- the counter does not count every shape"
[ "${AM:-999999}" -le 320 ] || fail "A: cached misses=$AM > 320 -- paragraphs re-shaped on opacity-only frames"
[ "${AH:-0}" -ge $((300 * 100)) ] || fail "A: cached hits=$AH < 30000 -- the paint path is not reading the cache"

echo "== B: JS driver (setNativeProps per dot per frame), windowed 6 s =="
windowed b-js ChatLoopJs 800 600 6 1
need_line "$WORK/b-js.log" 'chatloop dots=3 native=0' "B: the dots did not run on the JS driver"
BF=$(sed -n 's/^rn-impeller: frame_scheduler .* frames=\([0-9]*\).*/\1/p' "$WORK/b-js.log" | tail -1)
BM=$(field "$WORK/b-js.log" misses); BH=$(field "$WORK/b-js.log" hits)
echo "   frames=$BF hits=$BH misses=$BM $(grep -o 'build_p50=[0-9]*' "$WORK/b-js.log" | tail -1)"
[ "${BF:-0}" -ge 60 ] || fail "B: only ${BF:-0} frames painted in 6 s"
[ "${BM:-999999}" -le 320 ] || fail "B: misses=$BM > 320 -- JS-driven opacity commits re-shaped the transcript"

echo "== C: every shaping input changes once; cached final frame == uncached =="
for t in c-cached:1 c-uncached1:0 c-uncached2:0; do
  windowed "${t%%:*}" ChatLoopMutate 480 640 4 "${t##*:}" \
    --screenshot "$WORK/${t%%:*}.ppm" --screenshot-after 3000
  need_line "$WORK/${t%%:*}.log" 'chatloop mutate done step=6' "${t%%:*}: the mutation sequence did not finish"
  [ -s "$WORK/${t%%:*}.ppm" ] || fail "${t%%:*}: no screenshot"
done
cmp -s "$WORK/c-uncached1.ppm" "$WORK/c-uncached2.ppm" \
  || fail "C control: two uncached runs differ -- the final frame is not reproducible, the cmp proves nothing"
CM=$(field "$WORK/c-cached.log" misses)
cmp -s "$WORK/c-cached.ppm" "$WORK/c-uncached1.ppm" \
  || fail "C: cached final frame differs from uncached -- a stale paragraph was painted (misses=$CM)"
echo "   cached == uncached ($(wc -c < "$WORK/c-cached.ppm") bytes), misses=$CM"
echo "PARA_CACHE_PASS"
