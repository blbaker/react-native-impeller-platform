#!/usr/bin/env bash
# parity item 13 GATE: load the bundle from a running Metro dev server.
#
# `--bundle http://127.0.0.1:<port>/index.bundle?platform=impeller&dev=true`
# used to be a FATAL (absolute file paths only). Now the engine fetches the
# bundle over its HTTP transport and runs it with the URL as its source URL.
#
#   a  the run fetches from Metro and mounts (scene_nodes > 0), no js-error
#   b  getDevServer().bundleLoadedFromServer === true and its url is the Metro
#      origin; SourceCode.scriptURL is the bundle URL (HMR/symbolication key)
#   c  the bundle reflects Metro's LIVE source: the gate edits a marker in
#      index.js between two runs, and the second run sees the new value
#   d  a dead server URL fails with a FATAL naming the URL (no hang)
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item13-metro-url"
APP_NAME="Item13Metro"

fail() { echo "METRO_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/MetroApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="metroapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item13Metro"; a.displayName="Metro Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 13 metro fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/metro-release.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/metro-release.bundle"
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
echo "   Metro is up"
URL="http://127.0.0.1:$PORT/index.bundle?platform=impeller&dev=true&minify=false"
dump() { grep -E '^\[js|bundle_fetch|scene_nodes|FATAL|js-error' "$1" | cut -c1-200 | sed 's/^/   /' >&2; }

run_url() {  # $1 = log, $2 = url
  set +e
  timeout 180 "$RESOLVED" --bundle "$2" --app-name "$APP_NAME" --headless --probe-banner off \
      --width 400 --height 300 > "$1" 2>&1
  local rc=$?
  set -e
  return $rc
}

echo "== a. fetch from Metro and mount =="
run_url "$WORK/a.log" "$URL" || { dump "$WORK/a.log"; fail "a: loading the bundle from Metro failed -- --bundle does not accept a Metro URL"; }
grep -qF "rn-impeller: bundle_fetch url=$URL" "$WORK/a.log" \
  || { dump "$WORK/a.log"; fail "a: no bundle_fetch line -- --bundle does not accept a Metro URL"; }
grep -qE '^rn-impeller: scene_nodes=[1-9]' "$WORK/a.log" || { dump "$WORK/a.log"; fail "a: the Metro bundle mounted nothing"; }
! grep -qE "js-error|Invariant Violation" "$WORK/a.log" || { dump "$WORK/a.log"; fail "a: the Metro bundle threw"; }
echo "   OK: fetched + mounted"

echo "== b. getDevServer / scriptURL =="
grep -qF '[js] METRO_FROM_SERVER true' "$WORK/a.log" \
  || { dump "$WORK/a.log"; fail "b: getDevServer().bundleLoadedFromServer should be true -- the script URL is not the Metro URL"; }
grep -qF "[js] METRO_URL http://127.0.0.1:$PORT/" "$WORK/a.log" \
  || { dump "$WORK/a.log"; fail "b: getDevServer().url should be http://127.0.0.1:$PORT/ -- the script URL is not the Metro URL"; }
grep -qF "[js] METRO_SCRIPT_URL $URL" "$WORK/a.log" \
  || { dump "$WORK/a.log"; fail "b: SourceCode.scriptURL should be the bundle URL -- the script URL is not the Metro URL"; }
echo "   OK: bundleLoadedFromServer true, url + scriptURL correct"

echo "== c. Metro serves the live source =="
sed -i 's/METRO_MARK_ORIGINAL/METRO_MARK_EDITED/' "$APP/index.js"
sleep 1
run_url "$WORK/c.log" "$URL" || { dump "$WORK/c.log"; fail "c: second Metro run failed"; }
grep -qF '[js] METRO_MARK METRO_MARK_EDITED' "$WORK/c.log" \
  || { dump "$WORK/c.log"; fail "c: after editing index.js the Metro bundle should carry METRO_MARK_EDITED -- the engine did not load Metro's live bundle"; }
echo "   OK: edit picked up without rebundling"

echo "== d. a dead server fails loudly =="
DEAD="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
set +e
timeout 60 "$RESOLVED" --bundle "http://127.0.0.1:$DEAD/index.bundle?platform=impeller" --app-name "$APP_NAME" \
    --headless --probe-banner off > "$WORK/d.log" 2>&1
DRC=$?
set -e
[ "$DRC" -ne 0 ] && [ "$DRC" -ne 124 ] && grep -q "FATAL: cannot fetch bundle from http://127.0.0.1:$DEAD/" "$WORK/d.log" \
  || { tail -5 "$WORK/d.log" | sed 's/^/   /' >&2; fail "d: a dead Metro URL should fail fast with a FATAL naming the URL (rc=$DRC) -- fetch errors are not reported"; }
echo "   OK: rc=$DRC, FATAL names the URL"

echo "METRO_GATE_PASS (bundle loaded from a live Metro server: mounts, bundleLoadedFromServer, scriptURL, live source, dead-server FATAL)"
