#!/usr/bin/env bash
# EXIT-RACE GATE: quitting while the JS thread is mid-tick must not crash.
#
# Found by ci-click-caret (SIGSEGV after RN_IMPELLER_WINDOW_OK); core dump:
#   EventPerformanceLogger::dispatchPendingEventTimingEntries
#   <- RuntimeScheduler_Modern::updateRendering <- runEventLoopTick (JS thread)
# while the main thread was in ~Scheduler. ~FabricHost now nulls the
# event-timing delegate and drains the JS thread before the Scheduler goes.
#
# A random-timing repro is a flake, not a gate, so the engine has a test probe
# (RNI_TEST_EXIT_RACE_MS) that PARKS a JS tick inside that exact delegate call
# at teardown and reports if the Scheduler is destroyed under it.
#
#   a  probe run x3: the parked tick finishes before teardown, exit 0
#   b  plain run x5 of an always-rendering app with a click: exit 0
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/exit-race"
APP_NAME="ExitRace"

fail() { echo "EXIT_RACE_GATE_FAIL: $*" >&2; exit 1; }

unset SDL_VIDEODRIVER || true
export DISPLAY="${DISPLAY:-:0}"

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"
bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH" > /dev/null || fail "engine build failed"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() {
  rni_kill_own
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "${RNI_ENGINE_PKG}" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/ExitRaceApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="exitraceapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="ExitRace"; a.displayName="Exit Race Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the exit-race fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"

B="$APP/impeller/build/exit-race.bundle"
mkdir -p "$(dirname "$B")"
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output "$B" > "$WORK/bundle.log" 2>&1 \
  || { tail -20 "$WORK/bundle.log" >&2; fail "bundle build failed"; }
E="$RESOLVED"
cd "$ROOT"

run() {  # $1 = log, rest = extra env
  local log="$1"; shift
  set +e
  env "$@" timeout 30 "$E" --window --probe-banner off --bundle "$B" --app-name ExitRace \
      --width 400 --height 300 --idle-skip --idle-run-sec 1.5 \
      --mouse-after-frames "3:down@20,20;up@20,20" > "$log" 2>&1
  local rc=$?
  set -e
  return $rc
}

echo "== a. parked JS tick at teardown (probe) x3 =="
for i in 1 2 3; do
  L="$WORK/probe$i.log"
  rc=0; run "$L" RNI_TEST_EXIT_RACE_MS=400 || rc=$?
  grep -q 'exit_race_probe installed' "$L" || { tail -20 "$L" >&2; fail "a$i: the probe was not installed -- the gate would be blind"; }
  grep -q 'exit_race_probe entered' "$L" || { tail -20 "$L" >&2; fail "a$i: no JS tick reached the event-timing delegate at teardown -- the gate would be blind"; }
  if grep -q 'exit_race_probe USE-AFTER-FREE' "$L"; then
    fail "a$i: the Scheduler was destroyed while a JS tick was inside its event-timing delegate (use-after-free on quit)"
  fi
  [ "$rc" -eq 0 ] || { tail -20 "$L" >&2; fail "a$i: exited $rc"; }
  grep -q 'RN_IMPELLER_WINDOW_OK app=ExitRace' "$L" || fail "a$i: no WINDOW_OK"
done
echo "   OK: 3/3 parked ticks finished before the Scheduler was destroyed, exit 0"

echo "== b. plain quit while rendering x5 =="
for i in 1 2 3 4 5; do
  L="$WORK/plain$i.log"
  rc=0; run "$L" RNI_NONE=1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -20 "$L" >&2; fail "b$i: exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$L" || fail "b$i: nothing mounted"
done
echo "   OK: 5/5 clean exits"

echo "EXIT_RACE_GATE_PASS (quit while a JS tick is inside the event-timing delegate: drained before ~Scheduler; 3 parked + 5 plain runs exit 0)"
