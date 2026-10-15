#!/usr/bin/env bash
# FP-54 GATE: frame timings in the React Native DevTools Performance panel.
#
# The app runs from Metro with the inspector (parity item 24). This gate plays
# DevTools (tools/cdp-probe.js trace): one JS-driven animation BEFORE
# Tracing.start, one INSIDE the recording, one AFTER Tracing.end. The app is
# idle (--idle-skip) between them, so every present belongs to one animation.
#
#   a  the trace has one BeginFrame/DrawFrame pair (RN FrameTimingSequence) per
#      present in the window: DrawFrame count == commits at stop - commits at
#      start (the host's per-present counter, == presents= at exit)
#   b  nothing is emitted while not recording: emitted == 0 at Tracing.start
#      (after animation 1) and emitted at exit == frames in the trace (after
#      animation 3)
#   c  timestamps are monotonic (DrawFrame ts and frameSeqId strictly rise,
#      BeginFrame <= DrawFrame) and on RN's clock: every frame lies between the
#      fixture's console.timeStamp('fp54-anim-start-2') and its end stamp
#      (+ 400 ms), which RN stamps itself
#   d  host spans arrive as TimeStamp events on "rn-impeller main", inside the
#      same window
# RNI_BIN=<rn-impeller> runs that binary instead of the packed one (pre-pass proof).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/fp54-devtools-frames"
APP_NAME="Fp54DevtoolsFrames"

fail() { echo "DEVTOOLS_FRAMES_FAIL: $*" >&2; exit 1; }

unset SDL_VIDEODRIVER || true
export DISPLAY="${DISPLAY:-:0}"

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"
if [ -z "${RNI_BIN:-}" ]; then
  bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH" > /dev/null || fail "engine build failed"
fi

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
APP="$WORK/FramesApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="framesapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Fp54DevtoolsFrames"; a.displayName="DevTools Frames Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
BIN="${RNI_BIN:-$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)}" \
  || fail "engine resolver failed"
cd "$ROOT"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
echo "== 2. Metro on 127.0.0.1:$PORT =="
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

echo "== 3. run the app, record a DevTools trace around one animation =="
L="$WORK/app.log"; P="$WORK/cdp.log"; T="$WORK/trace.json"
set +e
"$BIN" --window --scale 1 --probe-banner off --supersample-rnsvg 0 --bundle "$URL" \
    --app-name "$APP_NAME" --width 400 --height 300 --idle-skip --idle-run-sec 25 > "$L" 2>&1 &
APP_PID=$!
rni_track "$APP_PID"
set -e
for _ in $(seq 1 120); do grep -q 'FP54_BOOT' "$L" && break; sleep 0.25; done
grep -q 'FP54_BOOT' "$L" || { tail -30 "$L" >&2; fail "the app never booted from Metro"; }
sleep 1  # first frames presented, app idle
set +e
NODE_PATH="$APP/node_modules" timeout 120 node "$CI_TOOLS/cdp-probe.js" \
    "http://127.0.0.1:$PORT" "$APP_NAME" trace "$T" > "$P" 2>&1
PRC=$?
wait "$APP_PID"; APPRC=$?
set -e
grep '^CDP ' "$P" | grep -v '^CDP pages' | sed 's/^/   /' | cut -c1-200
grep -E 'devtools_(trace|frames)|^rn-impeller: presents=' "$L" | sed 's/^/   app: /'
[ "$PRC" -eq 0 ] || { tail -20 "$P" >&2; fail "the CDP probe exited $PRC"; }
[ "$APPRC" -eq 0 ] || { tail -25 "$L" >&2; fail "the app exited $APPRC"; }
grep -q '^CDP tracing_end {"ok":true,"complete":true' "$P" \
  || fail "Tracing.end did not complete -- no trace to check"

echo "== 4. check the trace =="
python3 "$CI_TOOLS/devtools_frames_check.py" "$T" "$L" "$P"
echo "DEVTOOLS_FRAMES_PASS (frames in the trace == presents while recording, none outside, monotonic, on RN's clock, host spans on rn-impeller main)"
