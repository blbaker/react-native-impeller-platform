#!/usr/bin/env bash
# ENG-05b gate: SVG path fill and stroke are anti-aliased at the platform's
# DEFAULT render settings on darwin.
#
# WHAT IS TRUE TODAY (measured 2026-10-07 on linux llvmpipe AND on the Mac's
# ANGLE-Metal binary, identical numbers): Impeller's own path route is aliased
# on both backends (0 partial-coverage pixels; the C API has no AA setter and
# ignores the target's sample count). The AA
# comes from --supersample-rnsvg: at N>=2 the whole tree renders into an Nx
# offscreen and is downsampled (paintTreeSupersampled). main.cpp defaults N to
# 4 on __APPLE__ for BOTH headless and windowed runs, so the Mac app gets it.
#
# Fixture: fixtures/eng05-aa (a filled disc and a stroked ring; a circle's edge
# is partial coverage at every angle when AA is on). Measured by
# tools/eng05-aa-analyse.py at 1x and 2x.
#   A. CONTROL, N=0: both shapes read 0% partial. Proves the counter sees
#      aliasing, so B's numbers are AA and not a counter that always says yes.
#   B. N=4: stroke >= 10% / 5% partial (1x / 2x), fill >= 1% / 0.5%, and at
#      least 8 distinct edge levels on each.
#   C. NO FLAG: the engine logs its default. On darwin it must be 4 and read
#      like B. On linux it must be 0 and read like A (the linux default).
#   D. N=4 on an OVERSIZE surface (2100 pt wide, so N x passes the 8192 px
#      offscreen limit and the whole-tree hook returns false). A big Retina
#      window is this case. The per-<Svg> hook still supersamples each icon,
#      so the paths must still read like B.
#
# NO-NPM MODE: renders the committed prebuilt bundle with the staged binary.
# The Mac runs: RNI_BIN=<darwin rn-impeller> bash tools/ci-path-aa.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "PATH_AA_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
BUNDLE="${RNI_TEST_BUNDLE:-$ROOT/fixtures/eng05-aa/prebuilt/eng05-aa.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  EXTRA_NPM="react-native-svg@15.15.5" \
    bash "$ROOT/tools/build-fixture-bundle.sh" eng05-aa Eng05AA \
    || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

render() {  # $1 tag  $2 N|default  [$3 width pt] -> $WORK/<tag>-{1,2}x.ppm, echoes logged N
  local tag="$1" n="$2" wpt="${3:-400}" s rc nodes
  local flag=()
  [ "$n" != "default" ] && flag=(--supersample-rnsvg "$n")
  for s in 1 2; do
    set +e
    "$ENGINE" --bundle "$BUNDLE" --app-name Eng05AA --headless --probe-banner off \
      --width $((wpt * s)) --height $((300 * s)) --scale "$s" "${flag[@]}" \
      --screenshot "$WORK/$tag-${s}x.ppm" > "$WORK/$tag-${s}x.log" 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || { tail -20 "$WORK/$tag-${s}x.log" >&2; fail "$tag ${s}x: render exited $rc"; }
    nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORK/$tag-${s}x.log" | tail -1)"
    [ -n "$nodes" ] && [ "$nodes" -gt 0 ] || fail "$tag ${s}x: scene_nodes=${nodes:-none}: fixture did not mount"
  done
  sed -n 's/^rn-impeller: supersample_rnsvg=\([0-9]*\)$/\1/p' "$WORK/$tag-1x.log" | tail -1
}

# check <tag> <mode: aliased|aa>  — reads eng05-aa-analyse.py's report
check() {
  python3 "$ROOT/tools/eng05-aa-analyse.py" "$WORK/$1-1x.ppm" "$WORK/$1-2x.ppm" > "$WORK/$1.report"
  python3 - "$WORK/$1.report" "$2" <<'PY'
import re, sys
rep, mode = open(sys.argv[1]).read(), sys.argv[2]
blocks = re.split(r'--- (\d)x[^\n]*\n', rep)[1:]
bad = []
MIN = {('STROKE_ring', '1'): 10.0, ('STROKE_ring', '2'): 5.0,
       ('FILL_disc', '1'): 1.0, ('FILL_disc', '2'): 0.5}
seen = 0
for sc, body in zip(blocks[0::2], blocks[1::2]):
    for name, pct, levels in re.findall(
            r'(\w+)\s+\d+ px \|.*?=\s+([\d.]+)% partial\s*\n\s*distinct luminance values: (\d+)', body):
        seen += 1
        pct, levels = float(pct), int(levels)
        if mode == 'aliased' and pct != 0.0:
            bad.append(f'{name} {sc}x {pct}% partial, want 0 (aliased control)')
        if mode == 'aa' and (pct < MIN[(name, sc)] or levels < 8):
            bad.append(f'{name} {sc}x {pct}% partial / {levels} levels, want >= {MIN[(name, sc)]}% / 8')
        print(f'   {name} {sc}x: {pct}% partial, {levels} levels')
if seen != 4:
    bad.append(f'{seen} region readings, want 4 (a region painted nothing or left the frame)')
for b in bad:
    print('BAD ' + b)
sys.exit(1 if bad else 0)
PY
}

echo "== A. control, --supersample-rnsvg 0: aliased =="
got="$(render n0 0)"; [ "$got" = "0" ] || fail "A: engine logged supersample_rnsvg=${got:-none}, want 0"
check n0 aliased || fail "A: the counter does not read aliasing at N=0, so B proves nothing"

echo "== B. --supersample-rnsvg 4: anti-aliased =="
got="$(render n4 4)"; [ "$got" = "4" ] || fail "B: engine logged supersample_rnsvg=${got:-none}, want 4"
check n4 aa || fail "B: path fill/stroke are not anti-aliased at N=4"

echo "== C. no flag: the platform default =="
got="$(render def default)"; DEF="$got"
if [ "$(uname -s)" = "Darwin" ]; then
  [ "$got" = "4" ] || fail "C: darwin default supersample_rnsvg=${got:-none}, want 4 (the Mac app would alias)"
  check def aa || fail "C: darwin default render is not anti-aliased"
else
  [ "$got" = "0" ] || fail "C: linux default supersample_rnsvg=${got:-none}, want 0"
  check def aliased || fail "C: linux default render changed"
fi

echo "== D. --supersample-rnsvg 4 on a 2100 pt surface: per-icon AA =="
got="$(render big 4 2100)"; [ "$got" = "4" ] || fail "D: engine logged supersample_rnsvg=${got:-none}, want 4"
check big aa || fail "D: paths alias when the surface is too big for the whole-tree offscreen"

echo "PATH_AA_GATE_PASS ($(uname -s) default supersample_rnsvg=$DEF)"
