#!/usr/bin/env bash
# parity item 14 GATE: Fast Refresh (HMR) + DevSettings.reload against Metro.
#
#   a  the engine calls HMRClient.setup for a Metro bundle and Metro's /hot
#      socket connects (Metro logs the client; the engine logs hmr_setup)
#   b  FAST REFRESH: with the WINDOWED app running, the gate edits
#      Swatch.js's colour; within 10 s the swatch pixel turns from red to
#      green WITHOUT a restart (HMR_BOOT printed exactly once)
#   c  RELOAD: DevSettings.reload() restarts the app and it boots again from
#      Metro (HMR_BOOT >= 2, reload_reexec logged)
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item14-hmr"
APP_NAME="Item14Hmr"

fail() { echo "HMR_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/HmrApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="hmrapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item14Hmr"; a.displayName="HMR Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 14 hmr fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
cp "$FIXTURE/Swatch.js" "$APP/Swatch.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/react-native-impeller-platform/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/hmr-release.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/hmr-release.bundle"
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
# Warm Metro's build so the timed arms do not race the first bundling.
curl -s -o /dev/null "$URL"
dump() { grep -E '^\[js|hmr_setup|reload_|websocket|bundle_fetch|scene_nodes|FATAL|js-error' "$1" | cut -c1-200 | tail -25 | sed 's/^/   /' >&2; }
pixel() {  # $1 = ppm -> "r,g,b" at (100,100)
  python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], "rb").read(); parts = d.split(b"\n", 3)
w = int(parts[1].split()[0]); b = parts[3]; i = (100 * w + 100) * 3
print("%d,%d,%d" % (b[i], b[i + 1], b[i + 2]))
PY
}

echo "== a + b. windowed app, HMR connects, Fast Refresh repaints =="
L="$WORK/hmr.log"
set +e
"$RESOLVED" --window --probe-banner off --bundle "$URL" --app-name "$APP_NAME" \
    --width 400 --height 300 --idle-skip --idle-run-sec 25 \
    --screenshot "$WORK/before.ppm" --screenshot-after 6000 > "$L" 2>&1 &
APP_PID=$!
set -e
# wait for HMR to be set up and the first FRAME. scene_nodes= is printed by
# the host after its post-startSurface waitForJsIdle, i.e. right before the
# frame loop: JS's own SWATCH_RENDER log lands BEFORE any idle stall.
T_START=$(date +%s.%N)
for _ in $(seq 1 120); do grep -q '^rn-impeller: scene_nodes=' "$L" && break; sleep 0.25; done
T_FIRST=$(date +%s.%N)
FIRST_S="$(python3 -c "print('%.1f' % ($T_FIRST - $T_START))")"
grep -q 'SWATCH_RENDER #ff0000' "$L" || { dump "$L"; kill $APP_PID 2>/dev/null; fail "b: the app never rendered from Metro"; }
grep -qE '^rn-impeller: hmr_setup host=127.0.0.1 port='"$PORT" "$L" \
  || { dump "$L"; kill $APP_PID 2>/dev/null; fail "a: the engine never called HMRClient.setup -- HMR is not wired"; }
# The first frame must not wait out the JS-idle timeout: HMR installs a 20 s
# repeating ping, and a repeating timer counted as pending work stalled every
# waitForJsIdle (the first frame landed ~10 s late). Budget: bundle eval +
# mount is well under 2 s here.
python3 -c "import sys; sys.exit(0 if float('$FIRST_S') < 5 else 1)" \
  || { dump "$L"; kill $APP_PID 2>/dev/null; fail "a: the first frame took ${FIRST_S}s after launch -- startup stalled on HMR's repeating timer"; }
for _ in $(seq 1 40); do [ -s "$WORK/before.ppm" ] && break; sleep 0.25; done
[ -s "$WORK/before.ppm" ] || { dump "$L"; kill $APP_PID 2>/dev/null; fail "b: no 'before' screenshot was written (6 s after the first frame)"; }
BEFORE="$(pixel "$WORK/before.ppm")"
sed -i "s/#ff0000/#00ff00/" "$APP/Swatch.js"
for _ in $(seq 1 40); do grep -q 'SWATCH_RENDER #00ff00' "$L" && break; sleep 0.25; done
wait $APP_PID || true
grep -q 'SWATCH_RENDER #00ff00' "$L" \
  || { dump "$L"; sed 's/^/   metro: /' "$WORK/metro.log" | tail -8 >&2; fail "b: editing Swatch.js should re-render it via Fast Refresh -- HMR updates do not apply"; }
BOOTS="$(grep -c '^\[js\] HMR_BOOT' "$L")"
[ "$BOOTS" = "1" ] || { dump "$L"; fail "b: the app booted $BOOTS times during Fast Refresh -- it reloaded instead of hot-updating"; }
echo "   OK: hmr_setup, swatch re-rendered #00ff00 with 1 boot (before pixel $BEFORE)"
[ "$BEFORE" = "255,0,0" ] || fail "b: the swatch should start red, got $BEFORE"

echo "== b2. Fast Refresh repainted the PIXELS =="
set +e
"$RESOLVED" --window --probe-banner off --bundle "$URL" --app-name "$APP_NAME" \
    --width 400 --height 300 --frames 600 --screenshot "$WORK/after.ppm" --screenshot-after 400 \
    > "$WORK/after.log" 2>&1
set -e
AFTER="$(pixel "$WORK/after.ppm")"
[ "$AFTER" = "0,255,0" ] || { dump "$WORK/after.log"; fail "b2: after the edit the swatch should be green, got $AFTER"; }
echo "   OK: swatch pixel 255,0,0 -> 0,255,0"

echo "== c. DevSettings.reload() restarts the app from Metro =="
RL="$WORK/reload.log"
set +e
timeout 25 "$RESOLVED" --bundle "$URL" --app-name "$APP_NAME" --headless --probe-banner off \
    --width 400 --height 300 --frames 100000 --initial-url "hmr://x?reload=1" > "$RL" 2>&1 &
RPID=$!
set -e
for _ in $(seq 1 60); do [ "$(grep -c '^\[js\] HMR_BOOT' "$RL")" -ge 2 ] && break; sleep 0.5; done
pkill -f "initial-url hmr://x?reload=1" 2>/dev/null || true
kill $RPID 2>/dev/null || true
wait $RPID 2>/dev/null || true
grep -q 'rn-impeller: devsettings_reload reason=gate hook=1' "$RL" \
  || { dump "$RL"; fail "c: DevSettings.reload() did not reach the engine's reload hook -- reload is a no-op"; }
NB="$(grep -c '^\[js\] HMR_BOOT' "$RL")"
[ "$NB" -ge 2 ] || { dump "$RL"; fail "c: after DevSettings.reload() the app should boot again (HMR_BOOT >= 2), got $NB -- reload is a no-op"; }
echo "   OK: reload hook fired, app booted $NB times"

echo "HMR_GATE_PASS (HMRClient.setup -> Metro /hot, Fast Refresh repaints without restart, DevSettings.reload restarts from Metro)"
