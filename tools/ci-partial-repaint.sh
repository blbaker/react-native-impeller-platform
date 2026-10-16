#!/usr/bin/env bash
# FP-18 GATE: partial repaint with Flutter's 0.7 rule
# (flow/compositor_context.cc kImpellerRepaintRatio).
#
# fixtures/fp18-partial-repaint, windowed under xvfb, 800x600, RNI_DAMAGE_LOG=1
# (one `damage frame= mode= w= h= px= surface_px=` line per presented frame,
# printed by the raster thread for what it actually repainted).
#   A  PartialSpinner (one box slides + spins over 300 static tiles), 300 frames,
#      RNI_TEST_PARTIAL_VERIFY=1: after the first partial frame EVERY frame
#      repaints <= 5% of the surface, >= 250 frames are partial, and every
#      partial frame equals the same frame repainted in full (0 mismatched px)
#   B  PartialFinite (the motion once, then rest): the captured final frame is
#      pixel-identical to a --partial-repaint off run, and the on run was partial
#   C  0.7 rule: PartialWide (damage 100% wide, ~61% high) is partial; PartialHuge
#      (~91% x 91%) is never partial and says reason=ratio
# Node-free: committed bundle + RNI_BIN. Linux only (darwin/win32: FP-19).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/fp18-partial-repaint/prebuilt/fp18-partial-repaint.bundle"
fail() { echo "PARTIAL_REPAINT_FAIL: $*" >&2; echo "PARTIAL_REPAINT_FAIL: $*"; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
[ "$(uname -s)" = Linux ] || fail "linux only (xvfb); darwin/win32 lanes come with FP-19"
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
else
  bash tools/engine-build.sh linux x64 > "${TMPDIR:-/tmp}/ci-partial-repaint-build.log" 2>&1 \
    || { tail -20 "${TMPDIR:-/tmp}/ci-partial-repaint-build.log" >&2; fail "engine build failed"; }
  BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
echo "engine: $BIN ($(sha256sum "$BIN" | cut -c1-12))"

WORK="$(mktemp -d)"
cleanup() { [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

run() {  # app tag frames [extra args...]
  local app="$1" tag="$2" frames="$3" rc=0; shift 3
  ( cd "$(dirname "$BIN")" && RNI_DAMAGE_LOG=1 timeout 240 \
      xvfb-run -a -f "$WORK/xvfb.auth" -s "-screen 0 1280x1024x24" "$BIN" --window --scale 1 \
      --width 800 --height 600 --bundle "$BUNDLE" --app-name "$app" \
      --probe-banner off --supersample-rnsvg 0 --frames "$frames" "$@" ) \
    > "$WORK/$tag.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$WORK/$tag.log" || fail "$tag: nothing mounted"
  grep -q '^rn-impeller: supersample_rnsvg=0' "$WORK/$tag.log" || fail "$tag: supersample_rnsvg is not 0"
}

echo "== render =="
RNI_TEST_PARTIAL_VERIFY=1 run PartialSpinner spinner 300
run PartialFinite finite-on 200 --screenshot "$WORK/finite-on.png" --screenshot-after-frames 190
run PartialFinite finite-off 200 --partial-repaint off --screenshot "$WORK/finite-off.png" \
  --screenshot-after-frames 190
run PartialWide wide 90
run PartialHuge huge 90

python3 tools/partial_repaint_check.py "$WORK" || fail "see the arm above"
echo "PARTIAL_REPAINT_PASS"
