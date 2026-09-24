#!/usr/bin/env bash
# ENG-DRAG (P0) GATE: press-drag-release capture — every move and the release
# between a press and its release go to the tag the PRESS captured, even after
# the cursor leaves that control's bounds.
#
# Impeller has no PointerDispatcher, whose job on other platforms is exactly
# this retention. FabricHost::dispatchTouch resolves its target by hit-testing
# the point every call, so a mid-drag move fed to it retargets to whatever is
# now under the cursor. That is the defect: a slider dragged past its track, or
# a button pressed and slid off, loses the gesture to a sibling or to nothing.
#
# The gate reuses the p9-input fixture: three disjoint boxes stacked
# vertically (top y0..100, mid y100..200, bot y200..300; all x0..400). It
# presses the TOP box and drags DOWN, and asserts three things that fail for
# different reasons:
#
#   1. CAPTURE — a move whose point is over the MID box still reports the TOP
#      box's tag. This is THE assertion: a re-hit-testing move would report the
#      mid tag here (the move point is genuinely inside mid), a captured move
#      reports the down tag. Comparing move-tag to the mid box's own tag (learned
#      by a --tap) makes "it retargeted" and "it stayed" distinguishable.
#   2. OFF-CONTROL RELEASE — a move AND the release at a point off the surface
#      entirely (200,2000) still report the top tag, not 0. A drag does not end
#      because the cursor left the window.
#   3. CAPTURE CLEARS — drag_captured_after=0. A release must reset the capture,
#      or the next click is swallowed as a drag move forever.
#
# ⚠️ HEADLESS ON PURPOSE, same as ci-input.sh: the capture logic is entirely
# platform-independent (begin/move/end on FabricHost); only the GLFW callbacks
# that feed it are not. Gating this on a working macOS window would leave the
# drag tier unverified on Linux.
set -euo pipefail
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p9-input"

fail() { echo "DRAG_GATE_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"
bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH" > /dev/null || fail "engine build failed"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() {
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "${RNI_ENGINE_PKG}" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/DragApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="dragapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9Input"; a.displayName="Drag Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the p9-input fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"

npx --no-install react-native init-impeller 2>&1 | sed 's/^/   /' || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"

echo "== 3. bundle --platform impeller =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    2>&1 | tail -3 | sed 's/^/   /'
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

run_probe() {
  # $1 = extra args (a single --tap/--drag spec pair), $2 = logfile
  local log="$2"
  set +e
  # shellcheck disable=SC2086
  "$RESOLVED" --headless --probe-banner off --bundle "$BUNDLE" \
              --app-name P9Input $1 > "$log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { sed 's/^/   /' "$log" >&2; fail "probe '$1' exited $rc"; }
}

echo "== 4. learn the top and mid box tags (so 'retargeted' is provable) =="
# The drag's discriminating move point (200,150) is inside the MID box. To
# prove a captured move reports the TOP tag rather than retargeting, the gate
# must know BOTH tags: retarget == "move reported the mid tag", capture ==
# "move reported the top tag". A bare "move==down" without knowing the mid tag
# cannot tell capture from a hit test that happens to return the same node.
run_probe "--tap 200,50" "$WORK/tap-top.log"
TOP_TAG="$(sed -n 's/^rn-impeller: tap_hit=\([0-9]*\) .*/\1/p' "$WORK/tap-top.log" | head -1)"
run_probe "--tap 200,150" "$WORK/tap-mid.log"
MID_TAG="$(sed -n 's/^rn-impeller: tap_hit=\([0-9]*\) .*/\1/p' "$WORK/tap-mid.log" | head -1)"
[ -n "$TOP_TAG" ] && [ "$TOP_TAG" != "0" ] || fail "no tag for the top box at 200,50"
[ -n "$MID_TAG" ] && [ "$MID_TAG" != "0" ] || fail "no tag for the mid box at 200,150"
[ "$TOP_TAG" != "$MID_TAG" ] \
  || fail "top and mid boxes returned the SAME tag ($TOP_TAG) — the hit test ignores geometry; the drag assertion below would be meaningless"
echo "   OK: top=$TOP_TAG mid=$MID_TAG (distinct)"

echo "== 5. drag: press top (200,50) -> over mid (200,150) -> off-surface (200,2000) -> release (200,2000) =="
# Press on top, waypoint inside the mid box, waypoint far off the surface, then
# release off the surface. The off-surface point is an INTERMEDIATE waypoint
# (so it emits a move line) AND the release, proving both a held move and the
# release survive the cursor leaving every control.
run_probe "--drag 200,50:200,150:200,2000:200,2000" "$WORK/drag.log"

DOWN="$(sed -n 's/^rn-impeller: drag_down_tag=\([0-9]*\) .*/\1/p' "$WORK/drag.log" | head -1)"
UP="$(sed -n 's/^rn-impeller: drag_up_tag=\([0-9]*\) .*/\1/p' "$WORK/drag.log" | head -1)"
CAP_AFTER="$(sed -n 's/^rn-impeller: drag_captured_after=\([0-9]*\)$/\1/p' "$WORK/drag.log" | head -1)"
# Two move lines: over mid, and off-surface. Read them in order.
MOVE_MID="$(sed -n 's/^rn-impeller: drag_move_tag=\([0-9]*\) at=200.0,150.0$/\1/p' "$WORK/drag.log" | head -1)"
MOVE_OFF="$(sed -n 's/^rn-impeller: drag_move_tag=\([0-9]*\) at=200.0,2000.0$/\1/p' "$WORK/drag.log" | head -1)"

[ -n "$DOWN" ] || { sed 's/^/   /' "$WORK/drag.log" >&2; fail "no drag_down_tag line"; }
[ -n "$MOVE_MID" ] || { sed 's/^/   /' "$WORK/drag.log" >&2; fail "no drag_move_tag line over the mid box (200,150)"; }
[ -n "$UP" ] || { sed 's/^/   /' "$WORK/drag.log" >&2; fail "no drag_up_tag line"; }

echo "   down=$DOWN move@mid=$MOVE_MID move@off=${MOVE_OFF:-<none>} up=$UP captured_after=${CAP_AFTER:-<none>}"

echo "== 6. assert 1/3: the press captured the top box =="
[ "$DOWN" = "$TOP_TAG" ] \
  || fail "drag_down_tag=$DOWN but the top box is $TOP_TAG — the press landed on the wrong node"
echo "   OK: press captured top ($DOWN)"

echo "== 7. assert 2/3: a move OVER THE MID BOX still reports the TOP tag =="
# THE assertion. The move point (200,150) is genuinely inside the mid box, so a
# re-hit-testing move returns $MID_TAG. A captured move returns $DOWN (== top).
[ "$MOVE_MID" != "$MID_TAG" ] \
  || fail "drag move over the mid box reported the MID tag ($MID_TAG) — the move re-hit-tested and RETARGETED. The drag is not captured; a slider dragged past its track loses the gesture."
[ "$MOVE_MID" = "$DOWN" ] \
  || fail "drag move over the mid box reported tag $MOVE_MID, not the captured down tag $DOWN — the move is neither retargeting nor holding the capture"
echo "   OK: move over mid stayed on the pressed top tag ($MOVE_MID), did NOT retarget to mid ($MID_TAG)"

echo "== 8. assert 3/3: an off-surface move + release still hold the tag, then clear =="
[ -n "$MOVE_OFF" ] && [ "$MOVE_OFF" = "$DOWN" ] \
  || fail "drag move off the surface reported '${MOVE_OFF:-<none>}', not the captured tag $DOWN — the drag dropped when the cursor left every control"
[ "$UP" = "$DOWN" ] \
  || fail "drag_up_tag=$UP, not the captured tag $DOWN — the release off the surface did not go to the pressed control"
[ "${CAP_AFTER:-1}" = "0" ] \
  || fail "drag_captured_after=$CAP_AFTER — the release did not clear the capture; the next click would be swallowed as a drag move"
echo "   OK: off-surface move+release held tag $DOWN, capture cleared after release"

echo "DRAG_GATE_PASS (top=$TOP_TAG mid=$MID_TAG; down=$DOWN move@mid=$MOVE_MID move@off=$MOVE_OFF up=$UP)"
