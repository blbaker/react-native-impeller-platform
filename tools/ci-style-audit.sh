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
# Arms C (secure field clipboard) and D (selectable Text, P1 item 15) drive
# input on their own scenes; see each below.
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
  roundedMixedBorder:SC-04
  outline:SC-09
  backfaceHidden:SC-10
  gradientRadial:SC-07
  filterBrightness:SC-11 filterGrayscale:SC-11
  filterBlur:SC-12 filterDropShadow:SC-12 mixBlendMode:SC-13 isolation:SC-13
  italic:SC-14 writingDirection:SC-14 textAlignJustify:SC-14
  textShadow:SC-15
  ellipsizeHead:SC-16 ellipsizeMiddle:SC-16
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

# D. selectable <Text> (P1 item 15): the Mac's own `select` scene ('SELECT ME',
# 32 pt, selectable). Every drag point comes from the CONTROL frame's glyph
# ink columns (tools/select-text-measure.py), never from the engine's offset
# report, so a defect that moves both the highlight and the report (a wrong
# cluster rect, a wrong hit mapping) cannot pass. darwin glyph x's differ
# from linux; deriving the points keeps one gate valid on both.
echo "== D. selectable Text: drag paints a highlight, Copy copies it =="
srun() {  # name, scene, extra args...
  local name="$1" scene="$2"; shift 2
  set +e
  ( cd "$(dirname "$BIN")" && RNI_DRAG_COPY=1 "$BIN" --bundle "$BUNDLE" --app-name probe \
      --headless --probe-banner off --width 400 --height 300 --initial-url "probe://$scene" \
      --supersample-rnsvg "$SS" "$@" --screenshot "$WORK/$name.ppm" ) > "$WORK/$name.log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -10 "$WORK/$name.log" >&2; fail "D: $name run exited $rc"; }
}
kv() { echo "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1==k {print $2}'; }
srun sel-ctl select-control
fr="$(grep -m1 -o 'node_frame=Paragraph,[0-9]*,[0-9.,]*' "$WORK/sel-ctl.log" | cut -d, -f3-6)"
[ -n "$fr" ] || fail "D: no Paragraph node_frame in the select-control run"
IFS=, read -r FX FY FW FH <<< "$fr"
FX=${FX%.*}; FY=${FY%.*}; FW=${FW%.*}; FH=${FH%.*}
m0="$(python3 "$ROOT/tools/select-text-measure.py" "$WORK/sel-ctl.ppm" "$WORK/sel-ctl.ppm" "$FX" "$FY" "$FW" "$FH")"
IFS=, read -r -a SEGS <<< "$(kv "$m0" SEGS)"
[ "${#SEGS[@]}" -eq 8 ] || fail "D: control shows ${#SEGS[@]} glyph columns, want 8 ('SELECT ME' minus the space): $m0"
sx0() { echo "${SEGS[$1]%-*}"; }; sx1() { echo "${SEGS[$1]#*-}"; }
YM=$((FY + FH / 2))
PX=$(( $(sx0 0) + ($(sx1 0) - $(sx0 0)) / 4 ))          # left quarter of 'S'
CX=$(( $(sx0 4) + 3 * ($(sx1 4) - $(sx0 4)) / 4 ))      # right quarter of 'C'
EX=$((FX + FW + 40))                                    # past the end
dcheck() {  # name, want-text, want-x1-lo, want-x1-hi
  local m; m="$(python3 "$ROOT/tools/select-text-measure.py" "$WORK/sel-ctl.ppm" "$WORK/$1.ppm" "$FX" "$FY" "$FW" "$FH")"
  echo "   $1: $(grep -m1 -o 'clipboard op=copy-text.*' "$WORK/$1.log" || echo 'no copy') | $m"
  grep -q "clipboard op=copy-text bytes=${#2} text=$2\$" "$WORK/$1.log" \
    || fail "D: $1 copied '$(grep -m1 -o 'text=.*' "$WORK/$1.log" || true)', want '$2'"
  local hl x0 x1 rows out core tint
  hl=$(kv "$m" HL); x0=$(kv "$m" HL_X0); x1=$(kv "$m" HL_X1); rows=$(kv "$m" HL_ROWS)
  out=$(kv "$m" HL_OUT); core=$(kv "$m" CORE); tint=$(kv "$m" CORE_TINT)
  [ "$hl" -gt 0 ] || fail "D: $1 painted no selection highlight"
  [ "$out" -lt 20 ] || fail "D: $1 highlight spills outside the paragraph ($out px)"
  [ "$x0" -le "$(sx0 0)" ] || fail "D: $1 highlight starts at x$x0, after the first glyph's ink (x$(sx0 0))"
  [ "$x1" -ge "$3" ] && [ "$x1" -lt "$4" ] \
    || fail "D: $1 highlight ends at x$x1, want [$3,$4) from the control's glyph columns"
  [ $((rows * 10)) -ge $((FH * 8)) ] || fail "D: $1 highlight is $rows rows tall, want >= 80% of the line ($FH)"
  [ "$core" -gt 50 ] || fail "D: $1 only $core glyph-core px under the highlight: instrument blind"
  [ $((tint * 10)) -lt "$core" ] || fail "D: $1 tinted $tint of $core glyph cores: highlight painted OVER the text"
}
srun sel-full select --drag "$PX,$YM:$EX,$YM"
dcheck sel-full 'SELECT ME' "$(sx1 7)" $((FX + FW + 2))
srun sel-part select --drag "$PX,$YM:$CX,$YM"
dcheck sel-part 'SELEC' "$(sx1 4)" "$(sx0 5)"
# A press with no travel selects nothing: no highlight, nothing copied.
srun sel-tap select --drag "$PX,$YM:$PX,$YM"
mt="$(python3 "$ROOT/tools/select-text-measure.py" "$WORK/sel-ctl.ppm" "$WORK/sel-tap.ppm" "$FX" "$FY" "$FW" "$FH")"
echo "   sel-tap: $mt"
[ "$(kv "$mt" HL)" -eq 0 ] || fail "D: sel-tap: a press with no drag painted a highlight"
! grep -q 'clipboard op=copy-text' "$WORK/sel-tap.log" || fail "D: sel-tap: a press with no drag copied text"

echo "STYLE_AUDIT_GATE_PASS landed=${#LANDED[@]} keep=${#KEEP[@]} select=1"
