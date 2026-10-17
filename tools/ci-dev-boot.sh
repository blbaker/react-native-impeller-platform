#!/usr/bin/env bash
# parity item 12 GATE: __DEV__ bundles boot, and app WebSockets work.
#
# Every --dev true bundle getEnforcing's WebSocketModule during
# InitializeCore; without it the bundle threw an Invariant Violation and
# mounted nothing (Mac audit: scene_nodes=0, blank window).
#
#   a  a --dev true bundle mounts (scene_nodes > 0) with no getEnforcing /
#      Invariant / js-error, and __DEV__ is true inside it
#   b  the run EXITS promptly (React DevTools probes ws://localhost:8097 on
#      every dev boot; a connect that never completes must not wedge exit)
#   c  WebSocket round trip against a local echo server: open, text echo,
#      binary echo (bytes 1,2,250), close 1000
#   d  wss:// fails loudly with an explicit message (no TLS yet), no hang
#   e  LogBox renders (its Image no longer crashes it): no "Element type is
#      invalid" in the run
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item12-dev-boot"
APP_NAME="Item12DevBoot"

fail() { echo "DEVBOOT_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/DevBootApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="devbootapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item12DevBoot"; a.displayName="Dev Boot Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 12 dev-boot fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/react-native-impeller-platform/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/devboot-release.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/devboot-release.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"











echo "== build the --dev true bundle =="
cd "$APP"
npx --no-install react-native bundle --platform impeller --dev true \
    --entry-file index.js --bundle-output impeller/build/dev.bundle > "$WORK/devbundle.log" 2>&1 \
  || { tail -5 "$WORK/devbundle.log" >&2; fail "the --dev true bundle did not build"; }
cd "$ROOT"
DEV="$APP/impeller/build/dev.bundle"

echo "== start the ws echo server =="
node "$CI_TOOLS/ws-echo-server.js" "$APP" > "$WORK/echo.log" 2>&1 &
ECHO_PID=$!
for _ in $(seq 1 50); do grep -q '^WS_ECHO_PORT ' "$WORK/echo.log" && break; sleep 0.1; done
PORT="$(sed -n 's/^WS_ECHO_PORT //p' "$WORK/echo.log")"
[ -n "$PORT" ] || { cat "$WORK/echo.log" >&2; fail "echo server did not start"; }
echo "   echo server on 127.0.0.1:$PORT"

echo "== run the dev bundle headless =="
L="$WORK/run.log"
T0=$(date +%s.%N)
set +e
timeout 60 "$RESOLVED" --bundle "$DEV" --app-name "$APP_NAME" --headless --probe-banner off \
    --width 400 --height 300 --initial-url "devboot://x?ws=ws%3A%2F%2F127.0.0.1%3A$PORT%2Fecho" \
    > "$L" 2>&1
RC=$?
set -e
T1=$(date +%s.%N)
kill "$ECHO_PID" 2>/dev/null || true
ELAPSED="$(python3 -c "print('%.1f' % ($T1 - $T0))")"
dump() { grep -E '^\[js|websocket|scene_nodes|Invariant' "$1" | cut -c1-200 | sed 's/^/   /' >&2; }

echo "== a. the dev bundle mounts =="
# (The quoted detail is squeezed onto one line so the FAIL line, which the
# mutation suite greps, keeps its tail on the same line.)
! grep -qE "getEnforcing|Invariant Violation|js-error" "$L" \
  || { dump "$L"; fail "a: the dev bundle threw at boot ($(grep -m1 -oE "getEnforcing\([^)]*\): '[A-Za-z]+'" "$L" | tr -d '\n')) -- a module __DEV__ bundles require is missing"; }
grep -qE '^rn-impeller: scene_nodes=[1-9]' "$L" \
  || { dump "$L"; fail "a: the dev bundle mounted nothing -- dev bundles do not boot"; }
grep -qF '[js] DEV_BOOT dev=true' "$L" || { dump "$L"; fail "a: __DEV__ is not true inside the bundle -- the gate did not run a dev bundle"; }
echo "   OK: mounted, __DEV__ true"

echo "== b. exits promptly =="
[ "$RC" -eq 0 ] || { dump "$L"; fail "b: the dev run exited $RC after ${ELAPSED}s -- a WebSocket connect wedged shutdown"; }
python3 -c "import sys; sys.exit(0 if float('$ELAPSED') < 20 else 1)" \
  || { dump "$L"; fail "b: the dev run took ${ELAPSED}s -- a WebSocket connect wedged shutdown"; }
echo "   OK: exit 0 in ${ELAPSED}s"

echo "== c. WebSocket round trip =="
for want in '[js] WS_OPEN' '[js] WS_ECHO_TEXT hello-impeller' '[js] WS_ECHO_BINARY 1,2,250' '[js] WS_CLOSED 1000'; do
  grep -qF "$want" "$L" || { dump "$L"; sed 's/^/   echo: /' "$WORK/echo.log" >&2; fail "c: JS never saw '$want' -- the WebSocket module does not work"; }
done
grep -q '^WS_ECHO_GOT binary 3$' "$WORK/echo.log" || fail "c: the echo server never received the 3-byte binary frame -- sendBinary is broken"
echo "   OK: open, text, binary, close"

echo "== d. wss:// fails loudly =="
grep -qE '^\[js\] WS_BAD_SCHEME 1006 .*wss:// is not supported' "$L" \
  || { dump "$L"; fail "d: a wss:// socket should fail with an explicit message -- unsupported schemes are not reported"; }
echo "   OK"

echo "== e. LogBox renders =="
! grep -q "Element type is invalid" "$L" || { dump "$L"; fail "e: LogBox crashed rendering (Element type is invalid) -- the Image placeholder is missing"; }
echo "   OK"

echo "DEVBOOT_GATE_PASS (dev bundle boots + exits promptly, WebSocket text/binary/close round trip, wss refused loudly, LogBox renders)"
