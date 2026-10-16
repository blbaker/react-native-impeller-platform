#!/usr/bin/env bash
# FP-50 gate: the fast unit layer (Flutter's TEST_P layer) and the draw-op dump.
#
#   1. builds and runs `rni-scenegraph-tests` through CTest: canned Fabric mutation lists -> the real
#      SceneGraph painter -> a text log of every Impeller builder call (scenegraph/DrawOpLog), asserted
#      case by case. No GPU, no JS, no Hermes. Needs >= 30 cases and must finish in under 5 s.
#   2. `rn-impeller --dump-draw-ops <file>` on a committed fixture: the file exists, has a frame section
#      with the SaveLayer/ClipRect ops the fixture paints, balances every Save with a Restore, and two runs
#      produce byte-identical dumps (stable format).
# Needs engine/build configured by tools/engine-build.sh. RNI_BIN overrides the engine binary.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail() { echo "UNIT_FAIL: $*" >&2; exit 1; }
BUILD="$ROOT/engine/build"
[ -f "$BUILD/build.ninja" ] || fail "engine/build is not configured (run tools/engine-build.sh first)"

echo "== build rni-scenegraph-tests =="
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
cmake --build "$BUILD" -j"$(nproc)" --target rni-scenegraph-tests > "$LOG" 2>&1 \
  || { tail -25 "$LOG" >&2; fail "rni-scenegraph-tests did not build"; }

echo "== ctest =="
ctest --test-dir "$BUILD" -R '^rni-scenegraph-tests$' --output-on-failure > "$LOG" 2>&1 \
  || { grep -E '^(FAIL|  /.*:[0-9]+: )' "$LOG" | head -30 >&2; fail "ctest rni-scenegraph-tests failed"; }
grep -E 'tests passed|Total Test time' "$LOG" | sed 's/^/   /'

SUMMARY="$("$BUILD/rni-scenegraph-tests" | tail -1)"
echo "   $SUMMARY"
CASES="$(sed -nE 's/.*: ([0-9]+) cases, ([0-9]+) failed, ([0-9]+) ms.*/\1/p' <<<"$SUMMARY")"
MS="$(sed -nE 's/.*: ([0-9]+) cases, ([0-9]+) failed, ([0-9]+) ms.*/\3/p' <<<"$SUMMARY")"
[ -n "$CASES" ] || fail "no summary line from rni-scenegraph-tests"
[ "$CASES" -ge 30 ] || fail "only $CASES cases (need >= 30)"
[ "$MS" -lt 5000 ] || fail "suite took ${MS} ms (limit 5000)"

echo "== --dump-draw-ops =="
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
elif [ "$(uname -s)" = Darwin ]; then
  BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else
  BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN"
BUNDLE="$ROOT/fixtures/fp41-backdrop/prebuilt/fp41-backdrop.bundle"
[ -s "$BUNDLE" ] || fail "no fixture bundle at $BUNDLE"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; rm -f "$LOG"' EXIT
for n in 1 2; do
  ( cd "$(dirname "$BIN")" && timeout 120 "$BIN" --bundle "$BUNDLE" --app-name Fp41Backdrop --headless \
      --width 400 --height 300 --probe-banner off --supersample-rnsvg 0 \
      --dump-draw-ops "$WORK/ops$n.txt" ) > "$WORK/run$n.log" 2>&1 \
    || { tail -10 "$WORK/run$n.log" >&2; fail "run $n exited non-zero"; }
  [ -s "$WORK/ops$n.txt" ] || fail "run $n wrote no --dump-draw-ops file"
done
OPS="$WORK/ops1.txt"
grep -qE '^frame [0-9]+ ops=[1-9][0-9]*$' "$OPS" || fail "no 'frame N ops=K' section in the dump"
grep -qE '^ *SaveLayer .*backdrop=blur\(' "$OPS" || fail "dump has no SaveLayer with a blur backdrop"
grep -qE '^ *ClipRect rect\(40,40,140,100\)' "$OPS" || fail "dump has no ClipRect for the blur view"
saves="$(grep -cE '^ *Save(Layer)?( |$)' "$OPS")"
restores="$(grep -cE '^ *Restore$' "$OPS")"
[ "$saves" -eq "$restores" ] || fail "unbalanced dump: $saves saves vs $restores restores"
cmp -s "$WORK/ops1.txt" "$WORK/ops2.txt" || fail "two runs dumped different ops (unstable format)"
echo "   dump ok: $(sed -n 1p "$OPS"), $saves save/restore pairs, two runs identical"

echo "UNIT_PASS cases=$CASES suite_ms=$MS"
