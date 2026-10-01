#!/usr/bin/env bash
# parity item 15 GATE: app console output appears in the Metro terminal.
#
# RN's setUpDeveloperTools wraps console.* to also send each line over the
# HMR socket (HMRClient.log -> {type:'log'}); Metro prints it when started
# with `--client-logs`. Works once items 12 (WebSocket), 13 (Metro URL) and
# 14 (HMRClient.setup) are in: this gate guards the chain end to end.
#
#   a  with --client-logs, the app's console.log lines (HMR_BOOT,
#      SWATCH_RENDER) appear in Metro's terminal as LOG lines
#   b  console.warn arrives as WARN
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item15-metro-logs"
APP_NAME="Item15MetroLogs"

fail() { echo "METROLOGS_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/MetroLogsApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="metrologsapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item15MetroLogs"; a.displayName="Metro Logs Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 15 metro-logs fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
cp "$FIXTURE/Swatch.js" "$APP/Swatch.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/hmr-release.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/hmr-release.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"














PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
echo "== start Metro with --client-logs on 127.0.0.1:$PORT =="
cd "$APP"
npx --no-install react-native start --port "$PORT" --host 127.0.0.1 --client-logs > "$WORK/metro.log" 2>&1 &
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

echo "== run the app against Metro =="
set +e
"$RESOLVED" --window --probe-banner off --bundle "$URL" --app-name "$APP_NAME" \
    --width 400 --height 300 --idle-skip --idle-run-sec 5 > "$WORK/app.log" 2>&1
set -e
sleep 1
M="$WORK/metro.log"
echo "== a. console.log reaches the Metro terminal =="
grep -qE 'LOG +HMR_BOOT pid-start' "$M" && grep -qE 'LOG +SWATCH_RENDER #ff0000' "$M" \
  || { grep -vE 'BUNDLE|▓|░|▒' "$M" | tail -12 | sed 's/^/   metro: /' >&2; fail "a: the app's console.log lines should appear in Metro's terminal -- client logs are not forwarded"; }
echo "   OK: LOG lines in Metro"
echo "== b. console.warn arrives as WARN =="
grep -qE 'WARN +METRO_LOG_WARN' "$M" \
  || { grep -vE 'BUNDLE|▓|░|▒' "$M" | tail -12 | sed 's/^/   metro: /' >&2; fail "b: console.warn should appear in Metro as WARN -- client logs are not forwarded"; }
echo "   OK: WARN line in Metro"

echo "METROLOGS_GATE_PASS (app console.log / console.warn printed by the Metro terminal via the HMR socket)"
