#!/usr/bin/env bash
# ci-expo-dev — the Expo probe served by `expo start` (dev=true) boots, and a
# saved edit repaints through Fast Refresh without a restart.
#
# Needs node + npm (it installs the probe from npm and runs @expo/cli), so it
# is a Linux gate; the Mac verifies the same thing with its own probe.
#
#   1. `expo start` serves an IMPELLER dev bundle: HTTP 200, and none of the
#      iOS-only variants a mis-resolved bundle carries (Settings.ios.js,
#      Platform.ios.js, Image.ios.js). Before the fix every module resolved as
#      ios (Expo's resolver threw on platform "impeller", the core shim's
#      retry-as-ios caught it) and boot died on SettingsManager.
#   2. A windowed run paints the probe: first frame has the #121213 background
#      and the #FFCB27 label, zero [js-error], HMR set up against expo start.
#   3. App.js is edited while it runs (BG -> #0b3d91): the app re-renders with
#      ONE boot (Fast Refresh, not a reload) and the later frame of the SAME
#      process shows the new colour.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
cd "$(dirname "$0")/.."
ROOT="$PWD"
FIX="$ROOT/fixtures/expo-host"
CHECK="$ROOT/tools/expo_host_check.py"
export PATH="$HOME/.local/bin:$PATH"
fail() { echo "EXPO_DEV_GATE_FAIL: $*" >&2; exit 1; }
unset SDL_VIDEODRIVER || true
export DISPLAY="${DISPLAY:-:0}"
command -v npm >/dev/null || fail "needs node + npm"
if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"; else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (tools/engine-build.sh, or set RNI_BIN)"

WORK="$(mktemp -d)"
EXPO_PID=""
cleanup() {
  if [ -n "$EXPO_PID" ]; then
    for p in $(pgrep -g "$EXPO_PID" 2>/dev/null); do kill "$p" 2>/dev/null || true; done
  fi
  rni_kill_own
  [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 0. the probe app, installed from npm with core packed from this tree =="
CORE_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/app"; mkdir -p "$APP"
cp "$FIX/package.json" "$FIX/metro.config.js" "$FIX/app.json" "$FIX/.watchmanconfig" "$APP/"
cp "$FIX/dev/index.js" "$FIX/dev/App.js" "$APP/"
cd "$APP"
node -e '
const fs = require("fs");
const p = JSON.parse(fs.readFileSync("package.json", "utf8"));
p.dependencies["@react-native-impeller/core"] = "file:" + process.argv[1];
fs.writeFileSync("package.json", JSON.stringify(p, null, 2));
' "$WORK/$CORE_TGZ"
npm install --no-audit --no-fund --omit=optional > "$WORK/npm.log" 2>&1 \
  || { tail -20 "$WORK/npm.log" >&2; fail "npm install"; }
echo "   expo $(node -p 'require("expo/package.json").version'), react-native $(node -p 'require("react-native/package.json").version')"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
echo "== 1. expo start on :$PORT serves an impeller dev bundle =="
# NOT CI=1: under CI @expo/cli turns watch mode off ("reloads are disabled"),
# so an edit never reaches Fast Refresh. stdin from /dev/null keeps it
# non-interactive instead.
setsid bash -c "EXPO_NO_TELEMETRY=1 exec npx --no-install expo start --port $PORT" < /dev/null > "$WORK/expo.log" 2>&1 &
EXPO_PID=$!
for _ in $(seq 1 120); do
  curl -s -m 2 "http://127.0.0.1:$PORT/status" 2>/dev/null | grep -q packager-status:running && break
  sleep 0.5
done
curl -s -m 2 "http://127.0.0.1:$PORT/status" | grep -q packager-status:running \
  || { tail -20 "$WORK/expo.log" >&2; fail "1: expo start did not come up"; }
URL="http://127.0.0.1:$PORT/index.bundle?platform=impeller&dev=true&minify=false"
CODE="$(curl -s -m 180 -o "$WORK/dev.bundle" -w '%{http_code}' "$URL")"
[ "$CODE" = 200 ] || { head -c 600 "$WORK/dev.bundle" >&2; echo >&2; fail "1: dev bundle HTTP $CODE"; }
for ios in Libraries/Settings/Settings.ios.js Libraries/Utilities/Platform.ios.js Libraries/Image/Image.ios.js; do
  ! grep -qF "react-native/$ios\"" "$WORK/dev.bundle" \
    || fail "1: the dev bundle carries $ios -- expo start resolved the bundle as ios"
done
echo "   OK: HTTP 200, $(wc -c < "$WORK/dev.bundle") bytes, no ios-only variants"

echo "== 2 + 3. windowed run, then edit App.js while it runs =="
L="$WORK/run.log"
cd "$ROOT"
"$BIN" --window --probe-banner off --bundle "$URL" --app-name main --width 480 --height 320 \
    --idle-skip --idle-run-sec 22 --screenshot-first "$WORK/before.ppm" \
    --screenshot "$WORK/after.ppm" --screenshot-after 15000 > "$L" 2>&1 &
APP_PID=$!
dump() { grep -E '^\[js|js-error|hmr_setup|websocket|scene_nodes|FATAL' "$L" | grep -v 'Deep imports' | cut -c1-200 | tail -20 | sed 's/^/   /' >&2; }
for _ in $(seq 1 240); do grep -q 'EXPO_DEV_RENDER #121213' "$L" && break; sleep 0.25; done
grep -q 'EXPO_DEV_RENDER #121213' "$L" || { dump; kill $APP_PID 2>/dev/null; fail "2: the app never rendered from expo start"; }
sleep 2
sed -i "s/const BG = '#121213';/const BG = '#0b3d91';/" "$APP/App.js"
for _ in $(seq 1 80); do grep -q 'EXPO_DEV_RENDER #0b3d91' "$L" && break; sleep 0.25; done
wait $APP_PID || true
grep -E 'hmr_setup|scene_nodes|EXPO_DEV_' "$L" | sed 's/^/   /'
if grep -q '^\[js-error\]' "$L"; then dump; fail "2: [js-error]: $(grep -m1 '^\[js-error\]' "$L" | cut -c1-160)"; fi
! grep -q "could not be found" "$L" || { dump; fail "2: a TurboModule lookup failed at boot"; }
grep -q '^rn-impeller: hmr_setup host=127.0.0.1 port='"$PORT" "$L" || { dump; fail "2: HMR was never set up against expo start"; }
[ -s "$WORK/before.ppm" ] || { dump; fail "2: no first-frame screenshot"; }
PX="$(python3 "$CHECK" ppm "$WORK/before.ppm")"; echo "   first frame: $PX"
YEL="$(echo "$PX" | sed -E 's/.*yellow=([0-9]+).*/\1/')"
[ "$YEL" -ge 150 ] || fail "2: the first frame has only $YEL #FFCB27 label pixels"
corner() { python3 -c "
import sys; sys.path.insert(0, '$ROOT/tools'); from expo_host_check import read_ppm
w, h, px = read_ppm('$1'); k = (12 * w + 12) * 3; print('%d,%d,%d' % (px[k], px[k+1], px[k+2]))"; }
near() { python3 -c "
a = [int(v) for v in '$1'.split(',')]; b = [int('$2'[i:i+2], 16) for i in (0, 2, 4)]
import sys; sys.exit(0 if all(abs(x - y) <= 6 for x, y in zip(a, b)) else 1)"; }
B="$(corner "$WORK/before.ppm")"
near "$B" 121213 || fail "2: first-frame background is $B, expected #121213"
echo "   OK: painted from expo start (bg $B, label px $YEL), 0 js-errors, HMR set up"

grep -q 'EXPO_DEV_RENDER #0b3d91' "$L" \
  || { dump; tail -8 "$WORK/expo.log" | sed 's/^/   expo: /' >&2; fail "3: editing App.js did not re-render the app (Fast Refresh did not apply)"; }
BOOTS="$(grep -c '^\[js\] EXPO_DEV_BOOT' "$L")"
[ "$BOOTS" = 1 ] || { dump; fail "3: the app booted $BOOTS times -- it reloaded instead of hot-updating"; }
[ -s "$WORK/after.ppm" ] || { dump; fail "3: no later screenshot from the same process"; }
A="$(corner "$WORK/after.ppm")"
near "$A" 0b3d91 || fail "3: after the edit the background is $A, expected #0b3d91 (re-rendered but not repainted)"
echo "   OK: Fast Refresh repainted $B -> $A in the same process, 1 boot"
echo "EXPO_DEV_PASS"
