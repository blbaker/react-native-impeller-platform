#!/usr/bin/env bash
# P10 GATE: networking — can a bundle actually make an HTTP request?
#
# ⛔ WHY THIS GATE ASSERTS TWO HALVES, AND WHY A ONE-HALF GATE IS WORSE THAN
# NO GATE. React Native's JavaScript half of networking is COMPLETE without any
# native module: whatwg-fetch installs a global `fetch` that is a real
# function, and XMLHttpRequest.js imports cleanly. So on this engine, before
# the Networking TurboModule existed:
#
#     typeof fetch === 'function'            -> true
#     TurboModuleRegistry.get('Networking')  -> null
#     await fetch(anything)                  -> never succeeds
#
# A gate checking `typeof fetch` passes against a totally dead network stack,
# and would have passed for the entire life of this project. So:
#
#   HALF 1  the NATIVE module resolves  (TurboModuleRegistry.get non-null)
#   HALF 2  a REAL request completes    (bytes from a real server, in pixels)
#
# Plus a POSITIVE CONTROL swatch that depends on nothing but React rendering.
# Without it, an engine that failed to boot paints every probe background —
# indistinguishable from "networking is broken", and reporting the latter off
# that run is a false attribution.
#
# Runs through the CONSUMER path like P1-P4 — tarballs into a pristine app
# outside the repo — because a seam that only works from the repo is not
# shipped.
set -euo pipefail
# ⛔ RESOLVE tools/ BEFORE the cd, per ci-p4.sh: sourcing via "$(dirname "$0")"
# AFTER it re-resolves a relative $0 against the repo root.
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p10-networking"

fail() { echo "P10_NETWORKING_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP (tools/base-app.sh failed)"
bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH" > /dev/null || fail "engine build failed"
ENGINE_LOCAL="$ROOT/${RNI_ENGINE_PKG}/bin/rn-impeller"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "== 1. transport self-tests (no JS runtime, no external network) =="
# These run FIRST and standalone because they isolate the transport from the
# RN runtime entirely. If step 5 fails but these pass, the defect is in the
# module/JS seam; if these fail, it is in the HTTP code itself. One gate that
# only ran the end-to-end test could not tell those apart.
URLPARSE="$("$ENGINE_LOCAL" --test-urlparse | tail -1)" || fail "urlparse self-test exited nonzero: $URLPARSE"
echo "   $URLPARSE"
case "$URLPARSE" in
  "url-selftest: PASS"*) ;;
  *) fail "url parse self-test did not pass: $URLPARSE" ;;
esac

# --test-http stands up its OWN loopback server on an ephemeral port and
# asserts the server saw the method, path, headers and body the client claimed
# to send. A test that only checked "the client got 200 back" would pass
# against a request that dropped every custom header.
HTTPRAW="$WORK/http-selftest.log"
"$ENGINE_LOCAL" --test-http > "$HTTPRAW" 2>&1 \
  || fail "http self-test exited nonzero: $(tail -1 "$HTTPRAW")"
HTTPTEST="$(tail -1 "$HTTPRAW")"
echo "   $HTTPTEST"
case "$HTTPTEST" in
  "http-selftest: PASS"*) ;;
  *) fail "http self-test did not pass: $HTTPTEST" ;;
esac

# ⛔ THE TLS ARMS SELF-SKIP ON AN UNREACHABLE NETWORK, AND `tail -1` COULD NOT SEE IT.
# Both certificate arms (self-signed = chain trust, wrong.host = hostname
# verification) call out to badssl.com and print "SKIP (no network): ..." rather
# than failing, because a network outage is not a verification failure. That is
# the right behaviour for the selftest and the WRONG thing for a gate to swallow:
# reading only the final PASS line, a run where BOTH negative controls skipped is
# byte-identical to a run where TLS verification was proven. An engine built with
# verify_none would go green on a runner with no egress.
#
# Measured 2026-09-08 on the macOS tester's report round: the mac's app-level
# probe proved TLS end to end, but nothing in THIS repo's gate suite would have
# caught a regression on a sandboxed CI box. So: a skip is ANNOUNCED with its
# reason, and RNI_REQUIRE_TLS=1 turns the skip itself into a failure for any
# machine that is supposed to have egress. Same contract as gate 7's
# RNI_REQUIRE_WIN — silence is not a pass.
if grep -q "SKIP (no network)" "$HTTPRAW"; then
  echo "   ⚠️  TLS NEGATIVE CONTROLS SKIPPED — certificate verification is NOT proven by this run:"
  grep "SKIP (no network)" "$HTTPRAW" | sed 's/^/     /'
  if [ "${RNI_REQUIRE_TLS:-0}" = "1" ]; then
    fail "RNI_REQUIRE_TLS=1 but the certificate arms skipped (no egress to badssl.com)"
  fi
  echo "     Set RNI_REQUIRE_TLS=1 to make this skip a failure."
else
  # Assert the arms did not merely fail to print — name them positively, so a
  # renamed or deleted assertion reddens here instead of vanishing quietly.
  grep -q "a bad certificate is REJECTED, not accepted    ok" "$HTTPRAW" \
    || fail "chain-trust arm did not report ok (and did not skip)"
  grep -q "a cert for the WRONG HOSTNAME is rejected      ok" "$HTTPRAW" \
    || fail "hostname-verification arm did not report ok (and did not skip)"
  echo "   TLS negative controls RAN: chain trust + hostname verification both rejected"
fi

# ---------------------------------------------------------------------------
echo "== 2. Networking must be in the manifest, reachable FROM JAVASCRIPT =="
# Not from C++. Reading methodMap_ in C++ answers "what did we register", which
# we already know; going through global.nativeModuleProxy answers "what can a
# bundle CALL".
RAW_MANIFEST="$WORK/manifest.raw"
MANIFEST="$WORK/manifest.txt"
# ⛔ CAPTURE THE ENGINE'S EXIT CODE, NOT THE PIPE'S — an engine that printed a
# perfect manifest and then CRASHED must not read as success. (ci-p4.sh learned
# this from a darwin segfault in ~ReactHost.)
if ! "$ENGINE_LOCAL" --list-modules > "$RAW_MANIFEST" 2>/dev/null; then
  tail -5 "$RAW_MANIFEST" 2>/dev/null
  fail "--list-modules exited non-zero — a complete manifest does NOT excuse a crash"
fi
sed 's/^\[js\] //' "$RAW_MANIFEST" > "$MANIFEST"
grep -q '^MODULE_MANIFEST_END$' "$MANIFEST" || fail "manifest is truncated"
grep -q '^module=Networking ' "$MANIFEST" || fail "module 'Networking' is missing from the seam manifest"
# Every method the shipped JS calls must be in the map. RCTNetworking.ios.js
# calls sendRequest/abortRequest/clearCookies; a module vending only some is a
# runtime "not a function" that a name-only check cannot see.
for m in sendRequest abortRequest clearCookies addListener removeListeners; do
  grep "^module=Networking " "$MANIFEST" | grep -q "$m" \
    || fail "Networking is registered but method '$m' is not in its method map"
done
echo "   Networking reachable from JS with all 5 methods"

# ---------------------------------------------------------------------------
echo "== 3. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "${RNI_ENGINE_PKG}" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/NetworkingApp"
# ⛔ `cp -R` (capital), not `cp -r`: node_modules/.bin/* are symlinks and
# BSD/macOS `cp -r` DEREFERENCES them, producing MODULE_NOT_FOUND that reads as
# a broken RN install rather than a broken copy.
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="networkingapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P10Fixture"; a.displayName="P10 Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

# ⛔ LAYER 3, inherited from ci-p4.sh: the INSTALLED shim must carry the
# RCTNetworking redirect. Without it the bundle resolves
# Libraries/Network/RCTNetworking.js to a self-referencing stub on this
# platform, and the NATIVE module can be perfect while fetch is 100% broken —
# the JS never reaches native at all.
INSTALLED_SHIM="$APP/node_modules/@react-native-impeller/core/src/metro-shims/index.js"
[ -f "$INSTALLED_SHIM" ] || fail "react-native-impeller is not installed in the consumer app"
grep -q 'Network/RCTNetworking.js' "$INSTALLED_SHIM" \
  || fail "installed shim is STALE — no redirect for Network/RCTNetworking.js; fetch would resolve to a self-referencing stub"
echo "   installed shim carries the RCTNetworking redirect"

# ---------------------------------------------------------------------------
echo "== 4. start the fixture HTTP server on an EPHEMERAL port =="
# Ephemeral, never hardcoded: a fixed port is flaky on a shared machine and
# silently wrong if something else is already listening — the gate would then
# be measuring someone else's server.
SERVER_LOG="$WORK/server.log"
node "$ROOT/tools/p10-server.js" "$FIXTURE/fixture.json" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
PORT=""
for _ in $(seq 1 50); do
  PORT="$(grep -oE '^PORT=[0-9]+' "$SERVER_LOG" 2>/dev/null | cut -d= -f2 || true)"
  [ -n "$PORT" ] && break
  sleep 0.1
done
[ -n "$PORT" ] || { cat "$SERVER_LOG"; fail "fixture server never reported a port"; }
kill -0 "$SERVER_PID" 2>/dev/null || fail "fixture server died immediately"
echo "   fixture server on 127.0.0.1:$PORT"

# The fixture's baseUrl carries a placeholder port; rewrite it with the real
# one. The FIXTURE stays the single source of geometry and expectations — only
# the port, which cannot be known ahead of time, is substituted.
RUNTIME_FIXTURE="$WORK/fixture.json"
node -e '
const fs=require("fs");
const g=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
g.baseUrl = "http://127.0.0.1:" + process.argv[2];
fs.writeFileSync(process.argv[3], JSON.stringify(g,null,2));
' "$FIXTURE/fixture.json" "$PORT" "$RUNTIME_FIXTURE"

# Prove the server actually serves before blaming the engine. If this curl
# fails, the defect is the gate's own server and reporting a networking
# failure would be a false attribution.
if command -v curl >/dev/null; then
  CTRL="$(curl -s --max-time 5 "http://127.0.0.1:$PORT/get" || true)"
  EXPECT_BODY="$(node -p "require('$FIXTURE/fixture.json').getRequest.expectBody")"
  [ "$CTRL" = "$EXPECT_BODY" ] \
    || fail "the GATE'S OWN server is wrong (got '$CTRL', want '$EXPECT_BODY') — not an engine defect"
  echo "   server pre-flight ok (curl got the expected token)"
fi

# ---------------------------------------------------------------------------
echo "== 5. swap in the P10 fixture and bundle --platform impeller =="
cp "$FIXTURE/index.js" "$APP/index.js"
cp "$RUNTIME_FIXTURE" "$APP/fixture.json"
npx --no-install react-native init-impeller 2>&1 | sed 's/^/   /' || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    2>&1 | tail -3 | sed 's/^/   /'
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

# ---------------------------------------------------------------------------
echo "== 6. build probe args FROM the fixture =="
mapfile -t ARGS < <(node "$ROOT/tools/fixture-probe-args.js" "$RUNTIME_FIXTURE" p10)

echo "== 7. run the engine on the fixture bundle =="
LOG="$WORK/engine.log"
set +e
"$RESOLVED" --headless --probe-banner off \
            --bundle "$BUNDLE" --app-name P10Fixture \
            --screenshot "$WORK/frame.ppm" \
            "${ARGS[@]}" > "$LOG" 2>&1
RC=$?
set -e
grep -vE '^W[0-9]{8} ' "$LOG" | grep -vE '^rn-impeller: (probe|node_frame)=' | sed 's/^/   /'
[ "$RC" -eq 0 ] || fail "engine exited $RC"

echo "== 8. assert: React actually mounted =="
if grep -q '\[js-exception\] (fatal' "$LOG"; then
  fail "the bundle threw a fatal JS exception (see log above)"
fi
NODES="$(grep -oE 'scene_nodes=[0-9]+' "$LOG" | cut -d= -f2)"
[ -n "$NODES" ] && [ "$NODES" -gt 0 ] || fail "scene graph is empty — Fabric never mounted"
PAINTED="$(grep -oE 'painted_nodes=[0-9]+' "$LOG" | cut -d= -f2)"
[ "${PAINTED:-0}" -gt 0 ] || fail "scene graph has $NODES nodes but painted 0"
echo "   scene_nodes=$NODES painted_nodes=$PAINTED"

# The requests must have reached NATIVE, not merely resolved in JS. The pixels
# prove JS received responses; this proves the calls crossed the seam — the
# same pairing ci-p4.sh makes with alerts_shown. A JS-side stub could satisfy
# either one alone.
COMPLETED="$(grep -oE 'net_requests_completed=[0-9]+' "$LOG" | cut -d= -f2)"
[ -n "$COMPLETED" ] || fail "engine never reported net_requests_completed"
# The fixture issues 4 requests: /get, /status, /post and the dead-port probe.
[ "$COMPLETED" -ge 4 ] \
  || fail "net_requests_completed=$COMPLETED — expected >=4; requests never reached native (the JS shim may be self-resolving)"
INFLIGHT="$(grep -oE 'net_in_flight=[0-9]+' "$LOG" | cut -d= -f2)"
[ "${INFLIGHT:-1}" -eq 0 ] \
  || fail "net_in_flight=$INFLIGHT — the settle timed out, so the frame was captured mid-request and every verdict below is unreliable"
echo "   net_requests_completed=$COMPLETED (the calls crossed into native), in_flight=0"

echo "== 9. assert BOTH halves IN PIXELS =="
node "$ROOT/tools/assert-fixture.js" p10 "$RUNTIME_FIXTURE" "$LOG" P10_NETWORKING_FAIL

if [ -n "${SCREENSHOT_OUT:-}" ]; then cp "$WORK/frame.ppm" "$SCREENSHOT_OUT"; echo "   screenshot -> $SCREENSHOT_OUT"; fi
echo "P10_NETWORKING_PASS (nodes=$NODES painted=$PAINTED port=$PORT)"
