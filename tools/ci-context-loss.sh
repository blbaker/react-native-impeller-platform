#!/usr/bin/env bash
# FP-32 gate: GPU context loss -> teardown + rebuild, then the same pixels.
# Model: shell/common/shell.cc OnPlatformViewDestroyed/Created (Rasterizer::
# Teardown/Setup on the raster thread, the IO resource context recreated, then
# ScheduleFrame); Flutter at our pin has no EGL_CONTEXT_LOST handler itself.
#
# Fixture fixtures/fp32-context-loss: an image, two lines of text, an <Svg>
# and a <world> (terrain + sprite atlas) in fixed boxes; a counter laid out
# off-window keeps JS measuring text. RNI_TEST_CONTEXT_LOSS_AT_FRAME forces a
# loss right after the listed presents: the raster thread reports it, queued
# frames are dropped, main rebuilds (EGL context, Impeller context + surface,
# IO context, partial-repaint objects, every cached texture, the typography
# contexts) and asks for a frame. RNI_TEST_CONTEXT_LOSS_PROBE writes the frame
# presented at the first loss (ref) and the first 3 presents after each
# recovery; --screenshot captures the last frame.
#
# ARMS (A/B/C the staged binary, S the ASan build, engine/build-asan):
#   A threaded, --supersample-rnsvg 4 (root offscreen), 10 losses
#   B threaded, --supersample-rnsvg 1 (per-<Svg> offscreen), 10 losses
#   C --raster-thread off, --supersample-rnsvg 0, 3 losses
#   S = A on the ASan/UBSan binary: no sanitizer report, same pixels
# Every arm: exit 0; L losses, L recoveries, 0 failed, nothing lost at exit;
# the ref frame shows all four boxes; for every loss one of its first 3
# presents equals ref (<= 0.1% px off by > 8) and so do all after it, and each
# box is checked by name; the final frame equals ref; JS rebuilt its own
# typography context (own_rebuilt >= 1); the drop line names the caches.
# CTX_LOSS_ARMS (default "A B C S") picks arms. RNI_BIN set = A B C only on
# that binary (ci-sanitize then runs it on ASan itself).
# Mutants: tools/mutation-verify-context-loss.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. tools/lib/own-procs.sh
BUNDLE="$ROOT/fixtures/fp32-context-loss/prebuilt/fp32-context-loss.bundle"
fail() { echo "CONTEXT_LOSS_FAIL: $*" >&2; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
. tools/lib/host-window.sh
[ "$(rni_host)" = linux ] || fail "linux (Xvfb) only: darwin Metal and Windows have no rebuild path yet"
ARMS="${CTX_LOSS_ARMS:-A B C S}"
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
  ARMS="${ARMS//S/}"
else
  bash tools/engine-build.sh linux x64 > "${TMPDIR:-/tmp}/ci-context-loss-build.log" 2>&1 \
    || { tail -20 "${TMPDIR:-/tmp}/ci-context-loss-build.log" >&2; fail "engine build failed"; }
  BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
echo "engine: $BIN ($(shasum -a 256 "$BIN" | cut -c1-12)) arms: $ARMS"

WORK="$(mktemp -d)"
cleanup() { rni_kill_own; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT
python3 - "$WORK/photo.png" <<'PY'
import struct, sys, zlib
w, h = 160, 120
raw = b"".join(b"\0" + bytes(v for x in range(w) for v in ((x * 255) // w, (y * 255) // h, ((x ^ y) & 31) * 8))
               for y in range(h))
def ch(t, b):
    c = struct.pack(">I", len(b)) + t + b
    return c + struct.pack(">I", zlib.crc32(t + b) & 0xFFFFFFFF)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                              + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b""))
PY

losses_list() {  # count -> "60,72,..." (12 presents apart: 3 probe frames + slack)
  python3 -c "import sys; print(','.join(str(60 + 12 * i) for i in range(int(sys.argv[1]))))" "$1"
}

run_arm() {  # tag bin losses ss offscreen(tree|svg|none) [extra args...]
  local tag="$1" bin="$2" n="$3" ss="$4" off="$5"; shift 5
  local dir="$WORK/$tag" rc=0 frames=$((60 + 12 * n + 40))
  mkdir -p "$dir"
  echo "== $tag: $n losses, supersample $ss $*"
  RNI_TEST_CONTEXT_LOSS_AT_FRAME="$(losses_list "$n")" RNI_TEST_CONTEXT_LOSS_PROBE="$dir" \
    rni_xrun "$dir/xauth" timeout 300 "$bin" --window --scale 1 --width 400 --height 300 \
      --supersample-rnsvg "$ss" --probe-banner off --app-name ContextLoss --bundle "$BUNDLE" \
      --initial-url "fp32://run?dir=$WORK" --frames "$frames" \
      --screenshot "$dir/final.ppm" --screenshot-after-frames $((frames - 5)) "$@" \
      > "$dir/run.log" 2>&1 || rc=$?
  [ "$rc" = 0 ] || { tail -15 "$dir/run.log" >&2; fail "$tag: exit $rc (crash across the losses?)"; }
  grep -q '^RN_IMPELLER_WINDOW_OK' "$dir/run.log" || fail "$tag: no RN_IMPELLER_WINDOW_OK"
  python3 tools/context_loss_check.py "$dir" "$tag" "$n" "$off" || exit 1
}

for arm in $ARMS; do
  case "$arm" in
    A) run_arm A "$BIN" 10 4 tree ;;
    B) run_arm B "$BIN" 10 1 svg ;;
    C) run_arm C "$BIN" 3 0 none --raster-thread off ;;
    S)
      SAN_LOG="$WORK/sanitize-build.log"
      bash tools/ci-sanitize.sh --build-only > "$SAN_LOG" 2>&1 \
        || { tail -15 "$SAN_LOG" >&2; fail "S: ASan build failed"; }
      SAN_BIN="$ROOT/engine/build-asan/stage/bin/rn-impeller"
      SYMBOLIZER="$(command -v llvm-symbolizer || ls /usr/bin/llvm-symbolizer-* 2>/dev/null | sort -V | tail -1)"
      mkdir -p "$WORK/S"
      s_rc=0
      ( ASAN_SYMBOLIZER_PATH="$SYMBOLIZER" RNI_TIME_SCALE=4 \
        ASAN_OPTIONS="detect_leaks=1:abort_on_error=1:log_path=$WORK/S/san" \
        LSAN_OPTIONS="suppressions=$ROOT/tools/sanitize/lsan_suppressions.txt:print_suppressions=0" \
        UBSAN_OPTIONS="print_stacktrace=1:suppressions=$ROOT/tools/sanitize/ubsan_suppressions.txt:log_path=$WORK/S/san" \
        run_arm S "$SAN_BIN" 10 4 tree ) || s_rc=$?
      if ls "$WORK"/S/san.* >/dev/null 2>&1; then
        for f in "$WORK"/S/san.*; do grep -m8 -E 'ERROR|runtime error|SUMMARY|^    #[0-9]+ ' "$f" >&2 || true; done
        fail "S: sanitizer report under forced context loss: $(grep -h -m1 -oE '(ERROR: [A-Za-z]+Sanitizer: [A-Za-z -]+|runtime error: [^:]*)' "$WORK"/S/san.* | head -1) at $(grep -h -m1 -oE ' in rni::[A-Za-z_:]+' "$WORK"/S/san.* | head -1)"
      fi
      [ "$s_rc" = 0 ] || fail "S: the ASan arm failed (rc $s_rc, see above)"
      ;;
    *) fail "unknown arm $arm" ;;
  esac
done
echo "CONTEXT_LOSS_PASS"
