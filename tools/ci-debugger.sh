#!/usr/bin/env bash
# parity item 24 GATE: React Native DevTools can debug an impeller app.
#
# Same wiring as RN's own hosts: a HostTarget (jsinspector-modern) is the
# debuggable page, the ReactInstance registers its Hermes runtime under it,
# and an InspectorPackagerConnection keeps a device socket open to Metro's
# /inspector/device. DevTools then attaches through Metro. This gate plays
# DevTools: tools/cdp-probe.js finds the page in /json/list and speaks CDP
# over its webSocketDebuggerUrl, exactly the URL DevTools opens.
#
#   a  the app is listed in Metro's /json/list (nativePageReloads)
#   b  Runtime.evaluate runs IN the app: '1 + 2' -> 3, and a fixture global
#      only this runtime has -> 'impeller-debuggee-42' (a stub debugger
#      answers -32601 here while every *.enable still says ok)
#   c  Debugger.pause stops the app (Debugger.paused arrives, JS is blocked)
#      and Debugger.resume restarts it (a 100 ms tick counter advances)
#   d  the app quits cleanly (exit 0) after a debugger session
#   f  the app quits cleanly with DevTools STILL ATTACHED (session open,
#      Runtime + Debugger enabled), and DevTools sees the socket close
#   e  a release bundle from a FILE starts no inspector (pays nothing)
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item24-debugger"
APP_NAME="Item24Debugger"

fail() { echo "DEBUGGER_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/DebuggerApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="debuggerapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item24Debugger"; a.displayName="Debugger Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 24 debugger fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/react-native-impeller-platform/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/debugger-release.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/debugger-release.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"


PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
echo "== start Metro on 127.0.0.1:$PORT =="
cd "$APP"
npx --no-install react-native start --port "$PORT" --host 127.0.0.1 > "$WORK/metro.log" 2>&1 &
METRO_PID=$!
cd "$ROOT"
cleanup_metro() { kill "$METRO_PID" 2>/dev/null || true; pkill -P "$METRO_PID" 2>/dev/null || true; }
trap 'cleanup_metro; cleanup' EXIT
for _ in $(seq 1 120); do
  curl -s "http://127.0.0.1:$PORT/status" 2>/dev/null | grep -q packager-status:running && break
  sleep 0.5
done
curl -s "http://127.0.0.1:$PORT/status" | grep -q packager-status:running \
  || { tail -20 "$WORK/metro.log" >&2; fail "Metro did not start"; }
URL="http://127.0.0.1:$PORT/index.bundle?platform=impeller&dev=true&minify=false"
curl -s -o /dev/null "$URL"

echo "== run the app from Metro and attach a CDP client =="
L="$WORK/app.log"
set +e
"$RESOLVED" --window --probe-banner off --bundle "$URL" --app-name "$APP_NAME" \
    --width 400 --height 300 --idle-skip --idle-run-sec 30 > "$L" 2>&1 &
APP_PID=$!
set -e
for _ in $(seq 1 80); do grep -q 'DEBUG_FIXTURE_BOOT' "$L" && break; sleep 0.25; done
grep -q 'DEBUG_FIXTURE_BOOT' "$L" || { tail -30 "$L" >&2; kill $APP_PID 2>/dev/null; fail "the app never booted from Metro"; }
P="$WORK/cdp.log"
set +e
NODE_PATH="$APP/node_modules" timeout 90 node "$CI_TOOLS/cdp-probe.js" "http://127.0.0.1:$PORT" "$APP_NAME" > "$P" 2>&1
PRC=$?
wait $APP_PID; APPRC=$?
set -e
sed 's/^/   /' "$P" | cut -c1-220
cdp() { grep -m1 "^CDP $1 " "$P" | cut -d' ' -f3-; }
dumpall() { tail -25 "$L" | sed 's/^/   app: /' >&2; }

echo "== a. listed in /json/list =="
PAGES="$(cdp pages)"
python3 - "$PAGES" "$APP_NAME" <<'PY' || { dumpall; fail "a: the app is not listed in Metro's /json/list -- no debuggable page"; }
import json, sys
pages = json.loads(sys.argv[1] or "[]")
mine = [p for p in pages if p.get("appId") == sys.argv[2]]
sys.exit(0 if mine and (mine[0].get("caps") or {}).get("nativePageReloads") else 1)
PY
echo "   OK: page listed (nativePageReloads)"

echo "== b. Runtime.evaluate runs in the app =="
M="$(cdp eval_math)"; G="$(cdp eval_global)"
[ "$M" = '{"type":"number","value":3}' ] \
  || { dumpall; fail "b: Runtime.evaluate('1 + 2') returned $M, want 3 -- the debugger cannot run code in the app"; }
[ "$G" = '{"type":"string","value":"impeller-debuggee-42"}' ] \
  || { dumpall; fail "b: Runtime.evaluate(__DEBUG_FIXTURE_MARK) returned $G -- the debugger cannot run code in the app"; }
echo "   OK: 1+2 -> 3, app global -> impeller-debuggee-42"

echo "== c. pause stops the app, resume restarts it =="
PAUSED="$(cdp paused)"; BLOCK="$(cdp tick_while_paused)"; TICKS="$(cdp ticks_after_resume)"
[ -n "$PAUSED" ] && [ "$PAUSED" != "null" ] || { dumpall; fail "c: Debugger.pause never produced Debugger.paused -- breakpoints cannot work"; }
[ "$BLOCK" = '"blocked"' ] || fail "c: JS kept answering while paused ($BLOCK) -- the pause did not stop the runtime"
python3 -c "import json,sys; a,b=json.loads(sys.argv[1]); sys.exit(0 if isinstance(a,int) and isinstance(b,int) and b>a else 1)" "$TICKS" \
  || { dumpall; fail "c: the app did not run again after Debugger.resume (ticks $TICKS)"; }
echo "   OK: paused $PAUSED, JS blocked while paused, ticks after resume $TICKS"

echo "== d. clean quit after a debugger session =="
[ "$PRC" -eq 0 ] || fail "d: the CDP client exited $PRC"
[ "$APPRC" -eq 0 ] || { dumpall; fail "d: the app exited $APPRC after a debugger session (teardown order)"; }
grep -q '^rn-impeller: inspector session connected' "$L" || fail "d: no inspector session was ever connected"
echo "   OK: exit 0"

echo "== f. quit with DevTools still attached =="
L2="$WORK/app-hold.log"; P2="$WORK/cdp-hold.log"
set +e
"$RESOLVED" --window --probe-banner off --bundle "$URL" --app-name "$APP_NAME" \
    --width 400 --height 300 --idle-skip --idle-run-sec 8 > "$L2" 2>&1 &
APP_PID=$!
set -e
for _ in $(seq 1 80); do grep -q 'DEBUG_FIXTURE_BOOT' "$L2" && break; sleep 0.25; done
set +e
NODE_PATH="$APP/node_modules" timeout 60 node "$CI_TOOLS/cdp-probe.js" "http://127.0.0.1:$PORT" "$APP_NAME" hold > "$P2" 2>&1
wait $APP_PID; HOLDRC=$?
set -e
sed 's/^/   /' "$P2" | grep -E "hold_" | cut -c1-220
grep -q '^CDP hold_attached {"runtime":true,"debugger":true,"eval":3}' "$P2" \
  || { tail -20 "$L2" | sed 's/^/   app: /' >&2; fail "f: DevTools did not attach for the quit-while-attached run -- the arm would be blind"; }
[ "$HOLDRC" -eq 0 ] \
  || { tail -25 "$L2" | sed 's/^/   app: /' >&2; fail "f: the app exited $HOLDRC when quit with DevTools attached (inspector teardown)"; }
grep -qE '^CDP hold_end \{"socket":"closed:' "$P2" \
  || fail "f: DevTools' socket stayed open after the app quit -- the session was not ended"
echo "   OK: quit with DevTools attached -> exit 0, DevTools socket closed"

echo "== e. release bundle from a file: no inspector =="
R="$WORK/release.log"
set +e
"$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name "$APP_NAME" \
    --width 400 --height 300 --idle-skip --idle-run-sec 2 > "$R" 2>&1
RRC=$?
set -e
[ "$RRC" -eq 0 ] || { tail -20 "$R" >&2; fail "e: the release run exited $RRC"; }
grep -q 'DEBUG_FIXTURE_BOOT' "$R" || fail "e: the release bundle never booted"
! grep -q 'inspector host up' "$R" || fail "e: a file:// release bundle started the inspector -- it must cost nothing"
echo "   OK: no inspector for a release file bundle"

echo "DEBUGGER_GATE_PASS (React Native DevTools over Metro: page listed, Runtime.evaluate in the app, pause/resume, clean quit, quit while attached, none for release)"
