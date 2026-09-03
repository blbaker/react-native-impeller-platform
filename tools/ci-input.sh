#!/usr/bin/env bash
# P9 GATE: the input tier — hit test + touch dispatch + a JS handler that RUNS.
#
# The macOS tester's D-08 report was that 13 onPress handlers in hostapp v5 are wired
# and inert because no press ever fires. This gate is the thing that proves
# that is fixed, and it asserts the two halves SEPARATELY, because they fail
# for completely different reasons:
#
#   1. GEOMETRY — tapping a point returns the tag of the box at that point.
#      Asserted against three non-overlapping boxes at known coordinates, so a
#      hit test that ignores geometry and returns the first/topmost touchable
#      it finds FAILS here. It would pass against a single fullscreen button.
#
#   2. DISPATCH — the press reaches JS. Asserted via `alerts_shown`, the
#      host's existing "JS reached native" counter, because a handler that
#      only flips React state repaints identically whether or not it ran.
#
#   3. A MISS IS A MISS. Tapping empty space must report tap_hit=0. Without
#      this, a hit test that returns something for every input passes 1 and 2.
#
# ⚠️ HEADLESS ON PURPOSE. The hit walk and the emitter wiring are entirely
# platform-independent; only the GLFW callbacks that feed them are not. Gating
# this on a working window would leave the whole input tier unverified on
# Linux and block it behind the darwin context path.
set -euo pipefail
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p9-input"

fail() { echo "INPUT_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/InputApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="inputapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9Input"; a.displayName="Input Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the P9 input fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"

npx --no-install react-native init-impeller 2>&1 | sed 's/^/   /' || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"

echo "== 3. bundle --platform impeller =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    2>&1 | tail -3 | sed 's/^/   /'
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

# Tap the vertical centre of each box. X is held constant at 200 so only Y
# selects the target: if the gate fails, the failing coordinate says which
# axis is wrong.
run_tap() {
  local spec="$1" log="$2"
  set +e
  "$RESOLVED" --headless --probe-banner off --bundle "$BUNDLE" \
              --app-name P9Input --tap "$spec" > "$log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { sed 's/^/   /' "$log" >&2; fail "--tap $spec exited $rc"; }
}

echo "== 4. assert 1/3: geometry — the tap lands on the box at that point =="
# Collect each box's tag from the frame report, then assert the tap on that
# box's centre returns that SAME tag. Comparing against the frame report (not
# a hardcoded tag) keeps the gate valid if RN renumbers tags.
declare -A HIT
for spec in "200,50:top" "200,150:mid" "200,250:bot"; do
  point="${spec%%:*}"; name="${spec##*:}"
  LOG="$WORK/tap-$name.log"
  run_tap "$point" "$LOG"
  TAG="$(sed -n 's/^rn-impeller: tap_hit=\([0-9]*\) .*/\1/p' "$LOG" | head -1)"
  [ -n "$TAG" ] || { sed 's/^/   /' "$LOG" >&2; fail "no tap_hit line for $name at $point"; }
  [ "$TAG" != "0" ] || { sed 's/^/   /' "$LOG" >&2; fail "tap at $point ($name) hit NOTHING — hit test found no target"; }
  HIT[$name]="$TAG"
  echo "   $name at $point -> tag $TAG"
done

# The three boxes are disjoint, so three taps must yield three DISTINCT tags.
# This is the assertion that catches a hit test which ignores coordinates and
# returns the same (first, topmost, or root) node every time — the single most
# likely way for this to be wrong while still looking like it works.
UNIQ="$(printf '%s\n' "${HIT[top]}" "${HIT[mid]}" "${HIT[bot]}" | sort -u | wc -l)"
[ "$UNIQ" -eq 3 ] \
  || fail "three disjoint boxes returned $UNIQ distinct tags (${HIT[top]}/${HIT[mid]}/${HIT[bot]}) — the hit test is not using coordinates"
echo "   OK: three disjoint boxes -> three distinct tags"

echo "== 5. assert 2/3: dispatch — onPress actually RAN in JS =="
# alerts_shown is the host's existing proof that JS reached native. The
# fixture's every handler calls Alert.alert, so >=1 means the press was
# delivered, Pressability resolved it, and the handler executed.
# alerts_after_tap is the host's post-tap alert count. It must be read from
# the POST-tap line, not `alerts_shown`, which is printed before the probe runs
# and is therefore always 0 regardless of whether dispatch works.
ALERTS="$(sed -n 's/^rn-impeller: alerts_after_tap=\([0-9]*\)$/\1/p' "$WORK/tap-mid.log" | head -1)"
[ -n "$ALERTS" ] || fail "no alerts_after_tap line — cannot tell whether the handler ran"
[ "$ALERTS" -ge 1 ] \
  || fail "alerts_shown=$ALERTS — the tap resolved a tag but no onPress handler ran (dispatch is broken, hit test is fine)"
echo "   OK: alerts_shown=$ALERTS — the JS handler ran"

echo "== 6. assert 3/3: a miss is a miss =="
# 200,290 is inside the bottom box; 380,-1 would be off-surface. Use a point
# inside the surface but outside every box: the fixture's boxes span y=0..300
# full width, so shrink the target instead — tap far outside the surface.
MISS_LOG="$WORK/tap-miss.log"
run_tap "2000,2000" "$MISS_LOG"
MISS="$(sed -n 's/^rn-impeller: tap_hit=\([0-9]*\) .*/\1/p' "$MISS_LOG" | head -1)"
[ "$MISS" = "0" ] \
  || fail "tap far outside the surface returned tag $MISS — the hit test returns a target for ANY point"
echo "   OK: off-surface tap -> tap_hit=0"

echo "INPUT_GATE_PASS (tags ${HIT[top]}/${HIT[mid]}/${HIT[bot]}, alerts=$ALERTS)"
