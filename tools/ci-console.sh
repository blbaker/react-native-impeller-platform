#!/usr/bin/env bash
# parity item 10 GATE: RN's console polyfill is installed (nativeLoggingHook).
#
# The engine replaced `console` with log/info/warn/error only, so
# console.assert was undefined and `new AbortController().abort()` threw
# "console.assert is not a function" (Mac audit, MEASURED). The engine now
# installs global.nativeLoggingHook, which makes RN's own polyfill build the
# full console.
#
# Arms (release bundle, headless):
#   a  typeof console.assert === 'function'
#   b  new AbortController().abort() does not throw; signal.aborted === true
#   c  console.assert(false, msg) logs "Assertion failed: msg" (not a throw)
#   d  console.table / console.debug exist; group/groupEnd work
#   e  multi-arg console.log is formatted by RN's polyfill (inspect), proving
#      the polyfill, not the engine fallback, owns console
#   f  no line is printed twice
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item10-console"
APP_NAME="Item10Console"

fail() { echo "CONSOLE_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/ConsoleApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="consoleapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item10Console"; a.displayName="Console Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 10 console fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/console.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/console.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"









run_headless() {  # $1 = log
  "$RESOLVED" --bundle "$BUNDLE" --app-name "$APP_NAME" --headless --probe-banner off \
      --width 400 --height 300 > "$1" 2>&1 || { tail -20 "$1" >&2; fail "headless run failed"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$1" || fail "the fixture mounted nothing"
}
has() { grep -qF -- "$2" "$1"; }
dump() { grep -E '^\[js\]' "$1" | sed 's/^/   /' >&2; }

run_headless "$WORK/run.log"
L="$WORK/run.log"
! grep -q 'CONSOLE_THREW' "$L" \
  || { dump "$L"; fail "a check threw: $(grep -m1 CONSOLE_THREW "$L") -- RN's console polyfill is not installed"; }

echo "== a. console.assert exists =="
has "$L" '[js] CONSOLE_ASSERT_TYPE ok function' \
  || { dump "$L"; fail "a: typeof console.assert should be 'function' -- RN's console polyfill is not installed"; }
echo "   OK"
echo "== b. AbortController.abort() =="
has "$L" '[js] CONSOLE_ABORT ok true' \
  || { dump "$L"; fail "b: new AbortController().abort() should not throw and signal.aborted should be true -- RN's console polyfill is not installed"; }
echo "   OK"
echo "== c. console.assert(false, msg) logs =="
has "$L" '[js] Assertion failed: expected-assert-message' \
  || { dump "$L"; fail "c: console.assert(false, msg) should log 'Assertion failed: msg' -- RN's console polyfill is not installed"; }
echo "   OK"
echo "== d. table / debug / group =="
has "$L" '[js] CONSOLE_TABLE_TYPE ok function' && has "$L" '[js] CONSOLE_DEBUG_TYPE ok function' \
  && has "$L" '[js] CONSOLE_GROUP ok done' \
  || { dump "$L"; fail "d: console.table/debug should exist and group/groupEnd work -- RN's console polyfill is not installed"; }
echo "   OK"
echo "== e. RN's polyfill formats multi-arg logs =="
grep -qE "^\[js\] 'MULTI', 1, \{ a: 2 \}$|^\[js\] MULTI, 1, \{ a: 2 \}$" "$L" \
  || { dump "$L"; fail "e: console.log('MULTI', 1, {a:2}) should be formatted by RN's polyfill (inspect) -- the engine fallback owns console, so the polyfill is not installed"; }
echo "   OK: $(grep -m1 MULTI "$L")"
echo "== f. no duplicate lines =="
N="$(grep -c '^\[js\] CONSOLE_ABORT ok' "$L")"
[ "$N" = "1" ] || { dump "$L"; fail "f: each log line must print once; CONSOLE_ABORT printed $N times -- console output is doubled"; }
echo "   OK"

echo "CONSOLE_GATE_PASS (nativeLoggingHook installed: console.assert, AbortController.abort, table/debug/group, polyfill formatting, no doubling)"
