#!/usr/bin/env bash
# ENG-13 gate: strokeDasharray / strokeDashoffset on RNSVG shapes.
#
# THE BUG. readSvgPaintProps never read strokeDasharray/strokeDashoffset, so
# every dashed SVG stroke (dotted dividers, progress rings, focus outlines)
# painted SOLID. Nothing failed: it just looked like a design choice.
#
# Fixture: fixtures/eng13-svg-dash (its header lists rows A..L). The measurer
# tools/svg-dash-measure.py checks each row's ink runs / dash count:
#   A control solid, B array form, C positive offset, D negative offset (wraps),
#   E odd list repeated, F zero-length + round caps = dots, G zero-length +
#   butt caps = nothing, H negative value = solid, I zero sum = solid,
#   J dashed circle (closed curve, 16 dashes), K dashed rect (11 dashes, the
#   last joins the first through the start corner), L two identical icons
#   that differ only in offset (per-icon texture cache key), M the
#   ENGINE-LEDGER acceptance case: a [C, C] ring paints full / 3/4 / 1/4 at
#   offsets 0 / C/4 / 3C/4 (the "grace ring" draw-on animation).
#
# Every arm runs at --supersample-rnsvg 0, 1 and 4: 0 is the linux default, 1
# is the per-icon offscreen + cache path (only reachable at N=1), 4 is the
# darwin default (whole-tree offscreen). The logged supersample_rnsvg= must
# match each request, so a dropped flag cannot fall back to a default.
#
# NO-NPM MODE: renders the committed prebuilt bundle with the staged binary.
# The Mac runs: RNI_BIN=<darwin rn-impeller> bash tools/ci-svg-dash.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "SVG_DASH_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/eng13-svg-dash"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/eng13-svg-dash.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  EXTRA_NPM="react-native-svg@15.15.5" \
    bash "$ROOT/tools/build-fixture-bundle.sh" eng13-svg-dash Eng13SvgDash \
    || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
MEASURE="$ROOT/tools/svg-dash-measure.py"
LEVELS="${SVG_DASH_LEVELS:-0 1 4}"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

render() {  # $1 N
  local n="$1" rc nodes ss
  set +e
  "$ENGINE" --bundle "$BUNDLE" --app-name Eng13SvgDash --probe-banner off \
    --width 400 --height 500 --supersample-rnsvg "$n" --headless \
    --screenshot "$WORK/n$n.ppm" > "$WORK/n$n.log" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$WORK/n$n.log" >&2; fail "N=$n: headless render exited $rc"; }
  nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORK/n$n.log" | tail -1)"
  [ -n "$nodes" ] && [ "$nodes" -gt 0 ] || { tail -20 "$WORK/n$n.log" >&2; fail "N=$n: scene_nodes=${nodes:-none}: fixture did not mount"; }
  ss="$(sed -n 's/^rn-impeller: supersample_rnsvg=\([0-9]*\)$/\1/p' "$WORK/n$n.log" | tail -1)"
  [ "$ss" = "$n" ] || fail "N=$n: engine logged supersample_rnsvg=${ss:-none}, the flag did not apply"
  local shapes
  shapes="$(grep -c '^rn-impeller: node_frame=RNSVG\(Line\|Circle\|Rect\),' "$WORK/n$n.log" || true)"
  [ "$shapes" = "16" ] || { grep node_frame=RNSVG "$WORK/n$n.log" | head >&2; fail "N=$n: $shapes RNSVG Line/Circle/Rect frames, want 16"; }
}

for n in $LEVELS; do
  echo "== N=$n: rows A..M =="
  render "$n"
  if ! python3 "$MEASURE" "$WORK/n$n.ppm" > "$WORK/n$n.measure" 2>&1; then
    sed 's/^/   /' "$WORK/n$n.measure" >&2
    fail "N=$n: $(grep -c '^FAIL' "$WORK/n$n.measure") arm(s) failed: $(grep '^FAIL' "$WORK/n$n.measure" | cut -d: -f1 | tr '\n' ' ')"
  fi
  sed 's/^/   /' "$WORK/n$n.measure"
done

echo "SVG_DASH_GATE_PASS (levels: $LEVELS)"
