#!/usr/bin/env bash
# STYLE AUDIT GATE (Mac engine audit, 2026-10-04). One headless render of the
# 66-cell probe grid (fixtures/style-audit, the macOS tester's probe/index.js
# verbatim) scored by tools/style-audit-measure.py, which carries the Mac's
# RULES table plus stricter companions for the landed items.
#
# Two arms, one render:
#   A. LANDED: every tile named in LANDED below must PASS. Each entry is one
#      audit item; the list grows as items land. On the binary the audit
#      measured (Mac f5fc6e1, sha 02cf8ea7) every one of them FAILS.
#   B. KEEP-GREEN: every tile in KEEP below (the features the audit found
#      working: transforms, radii, per-side borders, rect clip, linear
#      gradient, zIndex, layout, textTransform, numberOfLines,
#      placeholderTextColor, ...) must still PASS.
# A tile in neither list is reported, not judged (open audit items).
#
# Node-free: the bundle is committed (tools/build-style-audit-bundle.sh
# regenerates it) and the measurer is pure python3, so the Mac runs
#   RNI_BIN=<darwin rn-impeller> bash tools/ci-style-audit.sh
# with no JS toolchain. Supersample is pinned (RNI_SUPERSAMPLE, default 0)
# and asserted from the log: darwin defaults to 4.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="${RNI_TEST_BUNDLE:-$ROOT/fixtures/style-audit/prebuilt/style-audit.bundle}"
SS="${RNI_SUPERSAMPLE:-0}"

# Audit items landed so far, as "<tile-id>:<item>".
LANDED=(
  shadowIOS:1 boxShadow:2 boxShadowInset:3 elevation:4
)
# Features the audit measured working on 02cf8ea7; must stay PASS.
# (aspectRatio and nestedTextSize are font/bundle sensitive across the Mac and
# linux builds of the same source -- see the audit thread -- and are judged only
# where the baseline passes them, via RNI_KEEP_EXTRA.)
KEEP=(
  opacityGroup translate scale rotate skewX transformOrigin perspective
  radiusPerCorner radiusPercent borderPerSide overflowRect gradientLinear
  zIndex absNegative gap rowColumnGap flexWrap textTransform numberOfLines
  placeholderColor statusBar ${RNI_KEEP_EXTRA:-}
)

fail() { echo "STYLE_AUDIT_GATE_FAIL: $*" >&2; exit 1; }

[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE (tools/build-style-audit-bundle.sh)"
OS="$(uname -s)"
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
elif [ "$OS" = Darwin ]; then
  BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else
  BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN, or run tools/engine-build.sh)"

WORK="$(mktemp -d)"
trap '[ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"' EXIT
LOG="$WORK/grid.log"; SHOT="$WORK/grid.ppm"

echo "== render: probe://grid 1200x2100 headless, supersample $SS =="
set +e
( cd "$(dirname "$BIN")" && "$BIN" --bundle "$BUNDLE" --app-name probe --headless \
    --probe-banner off --width 1200 --height 2100 --initial-url probe://grid \
    --supersample-rnsvg "$SS" --screenshot "$SHOT" ) > "$LOG" 2>&1
RC=$?
set -e
[ "$RC" -eq 0 ] || { tail -20 "$LOG" >&2; fail "render exited $RC"; }
grep -q 'RN_IMPELLER_RENDER_OK app=probe' "$LOG" || fail "no RENDER_OK line"
grep -qE 'scene_nodes=[1-9][0-9]{2}' "$LOG" \
  || fail "scene too small ($(grep -m1 scene_nodes "$LOG")): app-name mismatch mounts nothing"
grep -q "supersample_rnsvg=$SS\$" "$LOG" \
  || fail "supersample not pinned to $SS ($(grep -m1 supersample_rnsvg "$LOG"))"
[ -s "$SHOT" ] || fail "no screenshot"

python3 "$ROOT/tools/style-audit-measure.py" "$SHOT" "$ROOT/fixtures/style-audit/index.js" > "$WORK/tiles.txt"
verdict() { awk -v t="$1" '$1=="TILE" && $3==t {print $4}' "$WORK/tiles.txt"; }

echo "== A. landed items must PASS =="
bad=""
for e in "${LANDED[@]}"; do
  t="${e%%:*}"; item="${e#*:}"; v="$(verdict "$t")"
  line="$(awk -v t="$t" '$1=="TILE" && $3==t' "$WORK/tiles.txt" | cut -c1-160)"
  echo "   item $item: $line"
  [ "$v" = PASS ] || bad="$bad $t"
done
[ -z "$bad" ] || fail "A: landed audit item(s) do not paint:$bad"

echo "== B. keep-green tiles must still PASS =="
for t in "${KEEP[@]}"; do
  v="$(verdict "$t")"
  [ -n "$v" ] || fail "B: tile $t missing from the measurer output"
  [ "$v" = PASS ] || { echo "   $(awk -v t="$t" '$1=="TILE" && $3==t' "$WORK/tiles.txt" | cut -c1-160)" >&2; bad="$bad $t"; }
done
[ -z "$bad" ] || fail "B: feature(s) that worked before the audit regressed:$bad"
echo "   ${#KEEP[@]} keep-green tiles PASS"

echo "== open audit items (reported, not judged) =="
awk '$1=="TILE" && $4!="PASS" {printf "   %s %s %s\n", $2, $3, $4}' "$WORK/tiles.txt"
grep TILES_FAILING "$WORK/tiles.txt" | sed 's/^/   /'
echo "STYLE_AUDIT_GATE_PASS landed=${#LANDED[@]} keep=${#KEEP[@]}"
