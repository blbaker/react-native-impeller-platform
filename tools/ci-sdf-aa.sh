#!/usr/bin/env bash
# FP-22 GATE: Impeller Flags::use_sdfs through SDK patch 0003 (--sdf-aa on|off, default off).
# Headless GL (supersample 0), node-free: prebuilt fixtures/fp22-sdf-aa bundle + RNI_BIN.
# Judge: tools/sdf_aa_gate.py. Arms, in order (the FAIL line names the first that breaks):
#   readback   context_flags line read back from the created context: off / on / default off,
#              sdk=0003 (an engine built against an SDK without the patch prints sdk=none)
#   default    no flag renders pixel-equal to --sdf-aa off
#   coverage   --sdf-aa on: circle >= 150, oval >= 200, rounded rect >= 60 partial-coverage pixels;
#              the circle's edge changes (>= 100 px) from Impeller's circle pipeline to the SDF
#   control    --sdf-aa off: oval and rounded rect have hard (tessellated) edges, <= 10 partial px
#   interior   pixels > 1.5 px inside every shape are equal off vs on
#   elsewhere  a continuous-corner path, an integer rect and everything > 1.5 px from an SDF
#              edge are equal off vs on
#   cli        --sdf-aa bogus exits 2
#   bash tools/ci-sdf-aa.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/fp22-sdf-aa/prebuilt/fp22-sdf-aa.bundle"
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
fail() { echo "SDF_AA_GATE_FAIL: $*"; exit 1; }
[ -x "$BIN" ] || fail "no engine binary at $BIN"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
python3 -c 'import numpy, PIL' 2> /dev/null || fail "python3 with numpy + PIL is required"
WORK="$(mktemp -d)"
trap '[ -n "${KEEP_WORKDIR:-}" ] && echo "kept $WORK" >&2 || rm -rf "$WORK"' EXIT

run() {  # tag [--sdf-aa X]: headless capture into $WORK/<tag>.ppm, log $WORK/<tag>.log
  local tag="$1"; shift
  set +e
  ( cd "$(dirname "$BIN")" && "$BIN" --headless --probe-banner off --bundle "$BUNDLE" --app-name Fp22SdfAa \
      --width 400 --height 300 --scale 1 --supersample-rnsvg 0 "$@" --screenshot "$WORK/$tag.ppm" ) \
    > "$WORK/$tag.log" 2>&1
  local rc=$?
  set -e
  return $rc
}
must_run() {
  local tag="$1"; shift
  run "$tag" "$@" || { tail -8 "$WORK/$tag.log"; fail "$tag: engine exited non-zero"; }
  grep -q 'scene_nodes=[1-9]' "$WORK/$tag.log" || fail "$tag: nothing mounted"
  [ -s "$WORK/$tag.ppm" ] || fail "$tag: no capture"
}
readback() {  # tag want
  local line; line="$(grep -m1 '^context_flags ' "$WORK/$1.log" || true)"
  echo "   $1: ${line:-<no context_flags line>}"
  [ -n "$line" ] || fail "readback: $1 printed no context_flags line"
  grep -q ' sdk=0003' <<< "$line" || fail "readback: $1 engine built against an SDK without patch 0003 ($line)"
  grep -q "^context_flags sdf_aa=$2 " <<< "$line" || fail "readback: $1 context reports '$line', want sdf_aa=$2"
}

echo "== render off / on / default =="
must_run off --sdf-aa off
must_run on --sdf-aa on
must_run default
readback off off; readback on on; readback default off

echo "== default == off =="
cmp -s "$WORK/off.ppm" "$WORK/default.ppm" || fail "default: no-flag capture differs from --sdf-aa off"
echo "   ok"

echo "== judge (tools/sdf_aa_gate.py) =="
OUT="$(python3 tools/sdf_aa_gate.py "$WORK/off.ppm" "$WORK/on.ppm")" || { echo "$OUT" | sed 's/^/   /'; echo "$OUT" | grep -m1 '^SDF_AA_GATE_FAIL' >&2; exit 1; }
echo "$OUT" | sed 's/^/   /'
echo "== cli =="
rc=0; run bogus --sdf-aa bogus || rc=$?
[ "$rc" = 2 ] || fail "cli: --sdf-aa bogus exited $rc, want 2"
echo "   ok: --sdf-aa bogus exits 2"

[ -z "${RNI_SDF_AA_SAVE:-}" ] || cp "$WORK/off.ppm" "$WORK/on.ppm" "$RNI_SDF_AA_SAVE/"
echo "SDF_AA_GATE_PASS"
