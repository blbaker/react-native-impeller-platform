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
#      lineHeight (12) and textInputMultiline (16) landed as ENG-23 / ENG-16
#      on feat/eng-overnight and are judged here too.
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
  textInputSecure:11 overflowRounded:13
  lineHeight:12 textInputMultiline:16
  fontWeight:5 fontWeightBold:5 textAlignCenter:7 textAlignRight:7
  underline:9 lineThrough:9 decorationColor:9
  borderDashed:10 borderDotted:25
  nestedText:P1-14 nestedTextSize:P1-14 textBackground:P1-14
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

# C. secureTextEntry (item 11) beyond pixels: a FOCUSED secure field still
# paints bullets (the edit-buffer paint path, not the unfocused one), and
# select-all + copy/cut never reach the clipboard. The plain control field in
# the same tile proves the instrument: it MUST copy, or "refused" means nothing.
# Tile 64 sits at cell (720,1800): control field centre (790,1865), secure
# field centre (910,1865).
echo "== C. secure field: focused paint + clipboard refused =="
crun() {  # name, --type spec
  set +e
  ( cd "$(dirname "$BIN")" && "$BIN" --bundle "$BUNDLE" --app-name probe --headless \
      --probe-banner off --width 1200 --height 2100 --initial-url probe://grid \
      --supersample-rnsvg "$SS" --type "$2" --screenshot "$WORK/$1.ppm" ) > "$WORK/$1.log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -10 "$WORK/$1.log" >&2; fail "C: $1 run exited $rc"; }
}
crun plain '790,1865:<SA><COPY>'
grep -q 'clipboard op=copy bytes=3' "$WORK/plain.log" \
  || fail "C: the PLAIN control field did not copy ($(grep -m1 'clipboard op' "$WORK/plain.log")): the refusal check below would be vacuous"
crun secure '910,1865:<SA><COPY><CUT>'
grep -q 'type_focus=[1-9]' "$WORK/secure.log" || fail "C: the secure field did not take focus"
n_ref="$(grep -c 'clipboard op=refused-secure' "$WORK/secure.log" || true)"
n_leak="$(grep -cE 'clipboard op=(copy|cut)' "$WORK/secure.log" || true)"
echo "   control copied 3 bytes; secure field: refused=$n_ref leaked=$n_leak"
[ "$n_leak" -eq 0 ] || fail "C: secure field put its value on the clipboard ($n_leak copy/cut ops)"
[ "$n_ref" -eq 2 ] || fail "C: secure field refusal count $n_ref, want 2 (copy + cut)"
python3 "$ROOT/tools/style-audit-measure.py" "$WORK/secure.ppm" "$ROOT/fixtures/style-audit/index.js" > "$WORK/secure-tiles.txt"
v="$(awk '$1=="TILE" && $3=="textInputSecure" {print $4}' "$WORK/secure-tiles.txt")"
[ "$v" = PASS ] || fail "C: FOCUSED secure field does not paint bullets ($(awk '$1=="TILE" && $3=="textInputSecure"' "$WORK/secure-tiles.txt" | cut -c1-120))"
echo "   focused secure field paints 3 bullets"

echo "STYLE_AUDIT_GATE_PASS landed=${#LANDED[@]} keep=${#KEEP[@]}"
