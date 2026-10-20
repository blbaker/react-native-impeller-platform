#!/usr/bin/env bash
# iOS gate: the software keyboard's show/hide reaches JS as RN's Keyboard events,
# and RN's own KeyboardAvoidingView moves the screen out of its way. An XCUITest
# (engine/ios/testhost/uitests/RniKeyboardUITests.m, no Xcode project) taps the
# TextInput at the bottom of fixtures/ios-keyboard (keyboard up, screenshot),
# then empty space (keyboard down, screenshot). Events come from
# engine/ios/RNIKeyboardEventsIOS.mm; the padding animates through
# LayoutAnimation, which RNIEngine's frame loop ticks.
#   bash tools/ci-ios-keyboard.sh   (on linux: RNI_MAC_HOST=<ssh host> runs it on a Mac)
# Arms (each failure prints `IOS_KEYBOARD_GATE FAIL <arm>: ...`):
#   X  the XCUITest passed (keyboard up, then down)
#   E  JS got keyboardWillShow + keyboardDidShow (height > 0, a duration and an
#      easing), then keyboardWillHide + keyboardDidHide
#   A  after keyboardDidShow the footer's layout ends at or above the keyboard's
#      top (it started at the bottom of the screen, under where the keyboard goes)
#   P  pixels: the footer's colour is on screen where its layout says, keyboard
#      up and keyboard down. onLayout alone cannot prove this: layout is
#      reported before mounting, so a layout that never reaches the screen
#      still logs the new position.
#   H  after keyboardDidHide the footer is back at the bottom
# Pass line: IOS_KEYBOARD_PASS (keyboard_top=<y> footer_up=<y> footer_down=<y>).
# Mutants: tools/mutation-verify-ios-keyboard.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-uitest.sh"
ios_begin ios-keyboard
FAILS=()
bad() { echo "IOS_KEYBOARD_GATE FAIL $1: $2"; FAILS+=("$1"); }
GEOM=fixtures/ios-keyboard/geometry.js
geo() { python3 -c "import sys; sys.path.insert(0, 'tools'); import ios_image_check as c; g = c.load_geometry('$GEOM'); print($1)"; }

bash tools/engine-build-ios.sh simulator > "$IOS_WORK/engine-build.log" 2>&1 \
  || { tail -25 "$IOS_WORK/engine-build.log"; echo "IOS_KEYBOARD_FAIL (engine build)"; exit 1; }
ios_build_testhost engine || { echo "IOS_KEYBOARD_FAIL (test host build)"; exit 1; }
ios_build_uitest engine/ios/testhost/uitests/RniKeyboardUITests.m RniKeyboardUITests \
  || { echo "IOS_KEYBOARD_FAIL (uitest build)"; exit 1; }
ios_sim_up || { echo "IOS_KEYBOARD_FAIL (simulator)"; exit 1; }

XLOG="$IOS_WORK/xcodebuild.log"
ios_run_uitest RniKeyboardUITests "$XLOG" RNI_UITEST_APP="$IOS_BID" \
  RNI_UITEST_ARGS="--test=engine --bundle=ios-keyboard.jsbundle --app=IosKeyboard --log-file=1" \
  RNI_INPUT_H="$(geo "g['input']['height']")" RNI_FOOTER_H="$(geo "g['footer']['height']")" \
  RNI_SHOT_UP="$IOS_WORK/up.png" RNI_SHOT_DOWN="$IOS_WORK/down.png"
XRC=$?
grep -E 'rni-uitest|error:|Test Case .* (passed|failed)' "$XLOG" | cut -c1-300 | head -12
[ "$XRC" = 0 ] || bad X "xcodebuild rc=$XRC: $(grep -m1 -E 'error:|failed' "$XLOG" | cut -c1-300)"

LOG="$IOS_WORK/app.log"
cp "$(ios_container)/Documents/testhost.log" "$LOG" 2> /dev/null || : > "$LOG"
grep -E 'rni-ios: keyboard_event (keyboardWill|keyboardDid)(Show|Hide)|\[js\] ios-kb|DEVEVENT: keyboard(Did|Will)(Show|Hide)' "$LOG" | head -30
ios_keep "$LOG" "$XLOG" "$IOS_WORK/up.png" "$IOS_WORK/down.png"

# Everything else is one pass over the JS log and the two screenshots.
OUT=$(python3 - "$LOG" "$GEOM" "$IOS_WORK/up.png" "$IOS_WORK/down.png" << 'PY'
import json, re, sys
sys.path.insert(0, 'tools')
import ios_image_check as c
log, geom, up_png, down_png = sys.argv[1:5]
g = c.load_geometry(geom)
lines = open(log, errors='replace').read().splitlines()
m = next((re.search(r'uikit_points=(\d+)x(\d+) uikit_scale=([0-9.]+)', l) for l in lines
          if 'uikit_points=' in l), None)
W, H, S = (float(m.group(1)), float(m.group(2)), float(m.group(3))) if m else (0, 0, 0)
seq = []  # ('event', name, payload) or ('footer', payload), in log order
for l in lines:
    e = re.search(r'\[js\] ios-kb (keyboard\w+) (\{.*\})', l)
    f = re.search(r'\[js\] ios-kb footer (\{.*\})', l)
    if e: seq.append(('event', e.group(1), json.loads(e.group(2))))
    elif f: seq.append(('footer', json.loads(f.group(1))))
names = [s[1] for s in seq if s[0] == 'event']
fails = []
def fail(arm, msg): fails.append('%s: %s' % (arm, msg))
# E
for want in ('keyboardWillShow', 'keyboardDidShow', 'keyboardWillHide', 'keyboardDidHide'):
    if want not in names: fail('E', 'JS never got ' + want)
shown = [s[2] for s in seq if s[0] == 'event' and s[1] == 'keyboardDidShow']
top = None
if shown:
    p = shown[0]
    top = p.get('screenY')
    if not (p.get('height') or 0) > 0 or not (p.get('duration') or 0) > 0 or not p.get('easing'):
        fail('E', 'keyboardDidShow payload is incomplete: %s' % json.dumps(p))
# A / H: the footer before the keyboard, while it is up (the last layout
# between keyboardDidShow and keyboardWillHide), and at the end.
def idx_of(name):
    return next((i for i, s in enumerate(seq) if s[0] == 'event' and s[1] == name), None)
i_show, i_hide = idx_of('keyboardDidShow'), idx_of('keyboardWillHide')
up = None
if i_show is not None:
    end = i_hide if i_hide is not None and i_hide > i_show else len(seq)
    during = [s[1] for s in seq[i_show + 1:end] if s[0] == 'footer']
    up = during[-1] if during else None
footers = [s[1] for s in seq if s[0] == 'footer']
first = footers[0] if footers else None
down = footers[-1] if footers else None
bottom = lambda f: f['y'] + f['height']
if not first: fail('A', 'no footer layout at all')
elif abs(bottom(first) - H) > 1: fail('A', 'the footer starts at %.1f, not the screen bottom %.0f' % (bottom(first), H))
if top is not None and first:
    if up is None: fail('A', 'no footer layout after keyboardDidShow (it never moved)')
    elif bottom(up) > top + 1: fail('A', 'footer ends at %.1f, below the keyboard top %.1f' % (bottom(up), top))
if first and down and 'keyboardDidHide' in names and abs(bottom(down) - bottom(first)) > 1:
    fail('H', 'the footer ends at %.1f after the keyboard went, not %.1f' % (bottom(down), bottom(first)))
# P
green = tuple(int(g['footer']['color'][i:i + 2], 16) for i in (1, 3, 5))
def probe(png, f, what):
    try:
        img = c.read_image(png)
    except Exception as ex:
        fail('P', 'no %s screenshot (%s)' % (what, ex)); return None
    px = tuple(c.px(img, int(W / 2 * S), int((f['y'] + f['height'] / 2) * S)))
    if px != green: fail('P', '%s: footer centre (%.0f) is %s on screen, not the footer %s' % (what, f['y'] + f['height'] / 2, px, green))
    return px
if S and up: probe(up_png, up, 'keyboard up')
if S and down: probe(down_png, down, 'keyboard down')
if not S: fail('P', 'no uikit_scale line')
print('SUMMARY keyboard_top=%s footer_first=%s footer_up=%s footer_down=%s events=%s' % (
    top, first and bottom(first), up and bottom(up), down and bottom(down), ','.join(names)))
print('PASSLINE keyboard_top=%s footer_up=%s footer_down=%s' % (
    top, up and up['y'], down and down['y']))
for f in fails: print('FAIL ' + f)
PY
)
echo "$OUT" | grep '^SUMMARY'
while IFS= read -r l; do
  case "$l" in FAIL\ *) arm="${l#FAIL }"; bad "${arm%%:*}" "${arm#*: }" ;; esac
done <<< "$OUT"

[ "${#FAILS[@]}" = 0 ] || { echo "IOS_KEYBOARD_FAIL (${FAILS[*]})"; exit 1; }
echo "IOS_KEYBOARD_PASS ($(echo "$OUT" | sed -n 's/^PASSLINE //p'))"
