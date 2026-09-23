#!/usr/bin/env bash
# ENG text GATE: ellipsis dots + textTransform, proven by pixels.
#
# ⛔ WHY PIXELS AND NOT "THE SETTER WAS CALLED".
# ImpellerParagraphStyleSetEllipsis could be called with the wrong string, on an
# unclamped paragraph, or after the style was already built — all of which link
# clean and log nothing. The only honest proof is that the DOTS appear on a
# clamped line and DO NOT on a clipped one, and that an uppercased label paints
# taller glyphs than the same label untransformed.
#
#   1. ELLIPSIS PRESENT. Row 0 (tail, default) must carry ink in the far-right
#      band where "…" sits AND where a bare clip would leave more background.
#   2. CLIP CONTROL. Row 1 (ellipsizeMode=clip) must NOT match row 0's right-edge
#      signature — the dots are absent. Discriminates "ellipsis always on" from
#      "ellipsis honours the mode".
#   3. TRANSFORM CHANGED THE GLYPHS. Row 2 (uppercase "aceos") must have strictly
#      more ink in the TOP band (above x-height, where capitals reach) than row 3
#      (same text untransformed). A no-op transform leaves the two identical.
set -euo pipefail
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p9-text"

fail() { echo "TEXT_GATE_FAIL: $*" >&2; exit 1; }

unset SDL_VIDEODRIVER || true
export DISPLAY="${DISPLAY:-:0}"
WIN_W=200
WIN_H=140

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"
bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH" > /dev/null || fail "engine build failed"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() {
  pgrep -x rn-impeller > /dev/null 2>&1 && pkill -x rn-impeller || true
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "${RNI_ENGINE_PKG}" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/TextApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="textapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9Text"; a.displayName="Text Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the text fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/text.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/text.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"

echo "== 3. render headless and probe pixels =="
SHOT="$WORK/text.ppm"
set +e
"$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name P9Text \
            --width "$WIN_W" --height "$WIN_H" --frames 400 \
            --screenshot "$SHOT" --screenshot-after 80 > "$WORK/text.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { tail -20 "$WORK/text.log" | sed 's/^/   /' >&2; fail "render exited $rc"; }
[ -s "$SHOT" ] || fail "no screenshot"

# Count dark pixels in an axis-aligned band of the PPM. "Dark" = luminance < 128,
# i.e. black text ink on the white page.
band_ink() {  # $1 ppm  $2 x0  $3 y0  $4 x1  $5 y1
  python3 - "$@" <<'PY'
import sys
path, x0, y0, x1, y1 = sys.argv[1], *map(int, sys.argv[2:6])
d = open(path, 'rb').read()
parts, i = [], 0
while len(parts) < 4:
    while d[i:i+1].isspace(): i += 1
    if d[i:i+1] == b'#':
        while d[i:i+1] != b'\n': i += 1
        continue
    s = i
    while not d[i:i+1].isspace(): i += 1
    parts.append(d[s:i])
w, h, px = int(parts[1]), int(parts[2]), d[i+1:]
ink = 0
for y in range(y0, y1):
    for x in range(x0, x1):
        o = (y * w + x) * 3
        r, g, b = px[o], px[o+1], px[o+2]
        if (r*299 + g*587 + b*114) // 1000 < 128:
            ink += 1
print(ink)
PY
}

# Row 0 tail-ellipsis vs Row 1 clip: sample the FAR-RIGHT band of each row where
# the "…" sits. The scale factor doubles pixels on a 2x surface, so read the real
# surface size from the PPM by proportion rather than hardcoding.
DIMS="$(python3 - "$SHOT" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
parts,i=[],0
while len(parts)<4:
    while d[i:i+1].isspace(): i+=1
    if d[i:i+1]==b'#':
        while d[i:i+1]!=b'\n': i+=1
        continue
    s=i
    while not d[i:i+1].isspace(): i+=1
    parts.append(d[s:i])
print(int(parts[1]), int(parts[2]))
PY
)"
PW="$(echo "$DIMS" | cut -d' ' -f1)"
PH="$(echo "$DIMS" | cut -d' ' -f2)"
# Layout is 200x140 points; the PPM may be 200x140 (1x) or 400x280 (2x). Map
# point rows to pixel rows by proportion.
py() { echo $(( $1 * PH / 140 )); }   # point-y -> pixel-y
px() { echo $(( $1 * PW / 200 )); }   # point-x -> pixel-x

# Right-edge band, last 30 points of width, each row's vertical extent.
R0_RIGHT="$(band_ink "$SHOT" "$(px 170)" "$(py 0)"   "$(px 200)" "$(py 35)")"
R1_RIGHT="$(band_ink "$SHOT" "$(px 170)" "$(py 35)"  "$(px 200)" "$(py 70)")"

echo "   ellipsis probe: row0(tail) right-band ink=$R0_RIGHT  row1(clip) right-band ink=$R1_RIGHT"
[ "$R0_RIGHT" -gt 0 ] \
  || fail "row 0 (tail ellipsis) has NO ink in its right band — the '…' was not painted. The clamped line was hard-cut, so ImpellerParagraphStyleSetEllipsis is not taking effect."
[ "$R0_RIGHT" -gt "$R1_RIGHT" ] \
  || fail "row 0 (tail) right-band ink ($R0_RIGHT) is not greater than row 1 (clip) ($R1_RIGHT) — the ellipsis dots are not distinguishing the two modes. Either clip also draws dots, or tail draws none."
echo "   OK: ellipsis dots present on tail, absent on clip (Δ=$(( R0_RIGHT - R1_RIGHT )) px)"

# textTransform: top band (above x-height) of row 2 (uppercase) vs row 3 (raw).
# fontSize 24, x-height ~ 0.5em, so the top ~9 points of each 35pt row is where
# capitals have ink and lowercase x-height letters do not.
R2_TOP="$(band_ink "$SHOT" "$(px 0)" "$(py 70)"  "$(px 90)" "$(py 79)")"
R3_TOP="$(band_ink "$SHOT" "$(px 0)" "$(py 105)" "$(px 90)" "$(py 114)")"
echo "   textTransform probe: row2(upper) top-band ink=$R2_TOP  row3(raw) top-band ink=$R3_TOP"
[ "$R2_TOP" -gt "$R3_TOP" ] \
  || fail "row 2 (textTransform=uppercase) top-band ink ($R2_TOP) is not greater than row 3 (raw '$R3_TOP') — the transform did not change the glyphs. 'aceos' uppercased reaches the cap line; raw x-height letters do not, so a working transform MUST paint more top-band ink."
echo "   OK: uppercase glyphs reach the cap line, raw do not (Δ=$(( R2_TOP - R3_TOP )) px)"

echo "TEXT_GATE_PASS (ellipsis dots on tail/absent on clip + textTransform changed the glyphs)"
