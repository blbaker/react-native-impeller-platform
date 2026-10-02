#!/usr/bin/env bash
# ENG-22 gate: <Text>/<TextInput> fontFamily reaches PAINT and click mapping,
# not just measure.
#
# THE BUG. ImpellerTextLayoutManager measured a run with its fontFamily, but
# SceneGraph painted every paragraph with no family, so a `Geist Mono` label got
# a box sized for Geist Mono and glyphs drawn in the fallback face. HostApp worked
# around it by dropping fontFamily everywhere (ENGINE-LEDGER ENG-22).
#
# THE ORACLE IS THE FONT FILE, NOT THE ENGINE. Geist Mono advances every glyph
# 600/1000 em (hmtx), so at fontSize 20 "iiiiiiiiii" and "MMMMMMMMMM" both span
# 120 pt. A proportional face makes the i-row about a third of the M-row. Ink
# widths are read from pixels; no glyph-exact compare, so any font stack works.
#
#   A. PARAGRAPH PAINT. Mono Text rows: i/M ink-width ratio >= 0.9, and each
#      row within 10 pt of the font's 120 pt.
#   B. CONTROL. Default-face Text rows: i/M ratio < 0.6. If this fails the
#      fallback is itself monospaced and arm A proves nothing.
#   C. MEASURE == PAINT. Each mono row's ink fits inside its measured
#      node_frame width (+2 pt). This is the original symptom: an M-row painted
#      in the fallback overflows the 120 pt box measure gave it.
#   D. TEXTINPUT PAINT. Mono TextInput rows: i/M ratio >= 0.9.
#   E. CLICK MAPPING (windowed). Click at the font's own cell boundary 5 of the
#      mono i-field (x = 20 + 4 inset + 5*12 + 2). The caret must land at 5.
#      Fallback boundaries are ~4.9 pt apart, so the same click lands at 10.
#   F. REGISTRATION. --font-dir logs font_registered=... ok=1.
#
# NO-NPM MODE: renders the committed prebuilt bundle with the staged binary.
# The Mac runs: RNI_BIN=<darwin rn-impeller> bash tools/ci-font-family.sh
# SKIP_WINDOW=1 skips arm E (no display).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "FONT_FAMILY_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/eng22-font-family"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/eng22-font-family.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  bash "$ROOT/tools/build-font-family-bundle.sh" || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
FONTS="$FIX/fonts"
[ -s "$FONTS/GeistMono-Regular.ttf" ] || fail "no fixture font at $FONTS"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

APP=Eng22FontFamily
COMMON=(--bundle "$BUNDLE" --app-name "$APP" --probe-banner off
        --width 400 --height 300 --supersample-rnsvg 0)
ROWS=(monoI:0:10:400:40 monoM:0:45:400:75 defI:0:80:400:110 defM:0:115:400:145
      tiI:20:152:320:184 tiM:20:197:320:229)

mounted() {  # $1 log
  local n
  n="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$1" | tail -1)"
  [ -n "$n" ] && [ "$n" -gt 0 ] || { tail -20 "$1" >&2; fail "scene_nodes=${n:-none}: fixture did not mount ($1)"; }
  grep -q '^rn-impeller: supersample_rnsvg=0$' "$1" \
    || fail "engine did not report supersample_rnsvg=0 (flag dropped; darwin defaults to 4)"
}
inkw() { sed -n "s/^$1 ink=[0-9]* left=[0-9a-zA-Z]* right=[0-9a-zA-Z]* width=\([0-9.]*\)$/\1/p" "$2"; }
framew() {  # $1 log $2 frame-y -> measured width of the Paragraph at that y
  sed -n "s/^rn-impeller: node_frame=Paragraph,[0-9]*,[0-9.]*,$2\.0,\([0-9.]*\),.*/\1/p" "$1" | head -1
}
ratio() { python3 -c "print(f'{$1/$2:.3f}' if $2 else 0)"; }
ge() { python3 -c "import sys; sys.exit(0 if $1 >= $2 else 1)"; }

echo "== F. render headless with --font-dir =="
set +e
"$ENGINE" "${COMMON[@]}" --headless --font-dir "$FONTS" \
  --screenshot "$WORK/font.ppm" > "$WORK/font.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { tail -20 "$WORK/font.log" >&2; fail "headless render exited $rc"; }
mounted "$WORK/font.log"
grep -q "^rn-impeller: font_registered=.*GeistMono-Regular.ttf ok=1$" "$WORK/font.log" \
  || { grep font_registered "$WORK/font.log" >&2 || true; fail "F: Geist Mono was not registered (no font_registered ... ok=1 line)"; }
echo "   OK F: $(grep -c 'font_registered=.* ok=1' "$WORK/font.log") face(s) registered"

python3 tools/font-ink-rows.py "$WORK/font.ppm" 400 300 "${ROWS[@]}" > "$WORK/ink.txt"
sed 's/^/   /' "$WORK/ink.txt"
MI="$(inkw monoI "$WORK/ink.txt")"; MM="$(inkw monoM "$WORK/ink.txt")"
DI="$(inkw defI "$WORK/ink.txt")";  DM="$(inkw defM "$WORK/ink.txt")"
TI="$(inkw tiI "$WORK/ink.txt")";   TM="$(inkw tiM "$WORK/ink.txt")"
for v in MI MM DI DM TI TM; do
  ge "${!v:-0}" 20 || fail "row $v painted almost no ink (${!v:-0} pt); the fixture did not render"
done

R_MONO="$(ratio "$MI" "$MM")"; R_DEF="$(ratio "$DI" "$DM")"; R_TI="$(ratio "$TI" "$TM")"

echo "== B. control: the default face is proportional =="
ge 0.6 "$R_DEF" && [ "$R_DEF" != "0.600" ] \
  || fail "B: default-face i/M ratio $R_DEF >= 0.6; the fallback is monospaced, so arms A/D cannot tell faces apart"
echo "   OK B: default i/M = $R_DEF"

echo "== A. Text paints in Geist Mono =="
ge "$R_MONO" 0.9 \
  || fail "A: mono Text i/M ink ratio $R_MONO < 0.9 (i=$MI M=$MM pt). The paragraph painted in a proportional face: fontFamily is not reaching the paint path"
for v in MI MM; do
  python3 -c "import sys; sys.exit(0 if abs(${!v} - 120) <= 10 else 1)" \
    || fail "A: $v ink width ${!v} pt is not within 10 pt of Geist Mono's 120 pt (10 x 600/1000 em x 20)"
done
echo "   OK A: mono i/M = $R_MONO (i=$MI M=$MM pt, font says 120)"

echo "== C. painted ink fits the measured box =="
for pair in "MI:10" "MM:45"; do
  v="${pair%%:*}"; y="${pair##*:}"
  FW="$(framew "$WORK/font.log" "$y")"
  [ -n "$FW" ] || fail "C: no node_frame for the Paragraph at y=$y"
  python3 -c "import sys; sys.exit(0 if ${!v} <= $FW + 2 else 1)" \
    || fail "C: $v painted ${!v} pt of ink inside a box measured $FW pt wide: measure and paint used different faces"
  echo "   OK C: $v ink ${!v} pt <= measured $FW pt"
done

echo "== D. TextInput paints in Geist Mono =="
ge "$R_TI" 0.9 \
  || fail "D: mono TextInput i/M ink ratio $R_TI < 0.9 (i=$TI M=$TM pt): the field painted in a proportional face"
echo "   OK D: field i/M = $R_TI"

if [ "${SKIP_WINDOW:-0}" = "1" ]; then
  echo "== E. SKIPPED (SKIP_WINDOW=1) =="
else
  echo "== E. a click maps through the same face =="
  CLICK_X=$((20 + 4 + 5 * 12 + 2))
  WARGS=("${COMMON[@]}" --window --frames 40 --font-dir "$FONTS"
         --click-after-frames "5:$CLICK_X,168")
  set +e
  if [ "$(uname)" = "Darwin" ]; then
    zsh tools/darwin-run-interactive.sh "$WORK/win.log" 60 -- "$ENGINE" "${WARGS[@]}"
  elif [ -z "${DISPLAY:-}" ] && command -v xvfb-run > /dev/null; then
    xvfb-run -a -s "-screen 0 1280x1024x24" "$ENGINE" "${WARGS[@]}" > "$WORK/win.log" 2>&1
  else
    "$ENGINE" "${WARGS[@]}" > "$WORK/win.log" 2>&1
  fi
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$WORK/win.log" >&2; fail "E: windowed run exited $rc"; }
  mounted "$WORK/win.log"
  POS="$(sed -n 's/^rn-impeller: caret tag=[0-9-]* pos=\([0-9]*\) .*/\1/p' "$WORK/win.log" | tail -1)"
  XS="$(sed -n 's/^rn-impeller: ti_glyph_x tag=[0-9-]* xs=//p' "$WORK/win.log" | tail -1)"
  echo "   click x=$CLICK_X -> caret $POS; boundaries $XS"
  [ "$POS" = "5" ] \
    || fail "E: click at Geist Mono cell boundary 5 put the caret at ${POS:-none}: click-to-caret measured the field in a different face than it painted"
  echo "   OK E: caret 5"
fi

echo "FONT_FAMILY_GATE_PASS (Text + TextInput paint in the measured face; click maps through it)"
