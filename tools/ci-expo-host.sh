#!/usr/bin/env bash
# ci-expo-host — an Expo app's own entry point boots on this engine.
#
# Proves the HOST side of Expo (engine/modules/ExpoHost.{h,cpp}): the
# `globalThis.expo` object expo-modules-core reads at module load, and the one
# native module Expo's boot path requires (ExpoAsset). Node-free: renders the
# committed bundles in fixtures/expo-host/prebuilt (tools/build-expo-host-bundles.sh),
# so the Mac runs it with RNI_BIN=<darwin binary> and nothing else.
#
#   A. The Mac's probe, verbatim (registerRootComponent from 'expo'): render OK,
#      painted_nodes > 0, ZERO [js-error] lines, and the pixels are the app's
#      (#121213 background, #FFCB27 text), not a blank surface.
#   B. The contract, through Expo's own JS: core classes + subclassing,
#      EventEmitter semantics, uuidv4/uuidv5 (v5 checked against Python's
#      uuid), module lookup + ExpoGo absent, and ExpoAsset.downloadAsync against
#      a real local HTTP server and a pre-seeded cache: download with and
#      without an MD5, a cache hit for a URL that 404s, a stale cache file
#      refetched, a 404 rejecting with a CodedError, a file:// passthrough and
#      a name that would escape the cache dir refused. Every file the engine
#      names is checked ON DISK against what the server sent.
#      SC-44: ExponentConstants (bare, manifest = fixtures/expo-host/app.json
#      found from the bundle's directory) and expo/fetch against the same
#      server: status/statusText, response + request headers, UTF-8 text,
#      POST body, redirect follow/manual/error, abort, a 200 KB body streamed
#      in chunks, and globalThis.fetch being expo's. The server's request log
#      must show the requests arrived.
#   C. --list-modules lists ExpoAsset, ExponentConstants and ExpoFetchModule
#      as expo_module= (and not as a TurboModule ^module= line, which
#      ci-p4/ci-p10 parse).
#   Every arm fails on "Cannot find native module" / "No native ... module found".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
cd "$(dirname "$0")/.."
ROOT="$PWD"
PRE="$ROOT/fixtures/expo-host/prebuilt"
CHECK="$ROOT/tools/expo_host_check.py"
fail() { echo "EXPO_HOST_GATE_FAIL: $*" >&2; exit 1; }
OS="$(uname -s)"
for b in expo-probe expo-contract; do
  [ -s "$PRE/$b.bundle" ] || fail "no committed bundle $PRE/$b.bundle (tools/build-expo-host-bundles.sh)"
done
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
elif [ "$OS" = Darwin ]; then
  BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
elif [ "$OS" = Linux ]; then
  BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
else
  fail "unsupported OS $OS"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (build it: tools/engine-build.sh, or set RNI_BIN)"
echo "engine: $BIN"

WORK="$(mktemp -d)"
SRV_PID=""
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true
  rni_kill_own
  [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

render() {  # render <bundle> <log> <ppm> [extra args...]
  local _bundle="$1" _log="$2" _ppm="$3"; shift 3
  set +e
  RNI_CACHE_DIR="$WORK/cache" RNI_DOCUMENTS_DIR="$WORK/docs" \
    "$BIN" --bundle "$_bundle" --app-name main --headless --width 960 --height 540 \
      --probe-banner off --screenshot "$_ppm" "$@" > "$_log" 2>&1
  local _rc=$?
  set -e
  return $_rc
}

no_js_errors() {  # no_js_errors <log> <arm>
  if grep -q '^\[js-error\]' "$1"; then
    grep '^\[js-error\]' "$1" | head -5 >&2
    fail "$2: $(grep -c '^\[js-error\]' "$1") [js-error] line(s), first: $(grep -m1 '^\[js-error\]' "$1" | cut -c1-160)"
  fi
  if grep -qE 'has not been registered|Cannot find native module|No native .* module found' "$1"; then
    grep -E 'has not been registered|Cannot find native module|No native .* module found' "$1" | head -3 >&2
    fail "$2: boot error in the log"
  fi
}

echo "== A. the Mac's probe: registerRootComponent from 'expo' =="
LOG="$WORK/probe.log"
render "$PRE/expo-probe.bundle" "$LOG" "$WORK/probe.ppm" || { tail -20 "$LOG" >&2; fail "A: engine exited non-zero"; }
grep -E 'painted_nodes|distinct_colors|RENDER_OK|scene_nodes' "$LOG" | sed 's/^/   /'
grep -q '^RN_IMPELLER_RENDER_OK' "$LOG" || fail "A: no RN_IMPELLER_RENDER_OK"
no_js_errors "$LOG" A
PAINTED="$(sed -n 's/^rn-impeller: painted_nodes=\([0-9]*\).*/\1/p' "$LOG" | tail -1)"
[ "${PAINTED:-0}" -gt 0 ] || fail "A: painted_nodes=${PAINTED:-missing} (Expo entry did not mount)"
PX="$(python3 "$CHECK" ppm "$WORK/probe.ppm")"
echo "   pixels: $PX"
BGF="$(echo "$PX" | sed -E 's/.*bg_frac=([0-9.]+).*/\1/')"
YEL="$(echo "$PX" | sed -E 's/.*yellow=([0-9]+).*/\1/')"
python3 -c "import sys; sys.exit(0 if float('$BGF') > 0.80 else 1)" || fail "A: background #121213 covers only $BGF of the frame"
[ "$YEL" -ge 200 ] || fail "A: only $YEL #FFCB27 text pixels (the label did not paint)"
echo "   A ok: painted_nodes=$PAINTED, 0 js-errors, bg=$BGF, text px=$YEL"

echo "== B. globalThis.expo contract through Expo's JS =="
SRV="$WORK/srv"; mkdir -p "$SRV" "$WORK/cache"
head -c 4096 /dev/urandom > "$SRV/a.bin"
head -c 3000 /dev/urandom > "$SRV/b.bin"
head -c 2500 /dev/urandom > "$SRV/e.bin"
head -c 1000 /dev/urandom > "$WORK/c-content.bin"   # never served: cache-only
head -c 1000 /dev/urandom > "$WORK/d-content.bin"   # never served, never cached
MD5B="$(python3 "$CHECK" md5file "$SRV/b.bin")"
MD5C="$(python3 "$CHECK" md5file "$WORK/c-content.bin")"
MD5D="$(python3 "$CHECK" md5file "$WORK/d-content.bin")"
MD5E="$(python3 "$CHECK" md5file "$SRV/e.bin")"
cp "$WORK/c-content.bin" "$WORK/cache/ExponentAsset-$MD5C.bin"
echo "stale bytes that do not hash to md5E" > "$WORK/cache/ExponentAsset-$MD5E.bin"

python3 "$CHECK" serve "$SRV" "$WORK/port" "$WORK/reqlog" &
SRV_PID=$!
for _ in $(seq 1 100); do [ -s "$WORK/port" ] && break; sleep 0.05; done
PORT="$(cat "$WORK/port" 2>/dev/null)"; [ -n "$PORT" ] || fail "B: test HTTP server did not start"
BASE="http://127.0.0.1:$PORT"
URL="rniexpo://contract?base=$BASE&md5B=$MD5B&md5C=$MD5C&md5D=$MD5D&md5E=$MD5E"

LOG="$WORK/contract.log"
render "$PRE/expo-contract.bundle" "$LOG" "$WORK/contract.ppm" --initial-url "$URL" \
  || { tail -20 "$LOG" >&2; fail "B: engine exited non-zero"; }
{ grep -E '^\[js\] EXPO_' "$LOG" || true; } | sed 's/^\[js\] /   /'
no_js_errors "$LOG" B
DONE="$(grep -m1 '^\[js\] EXPO_CONTRACT_DONE' "$LOG" || true)"
[ -n "$DONE" ] || fail "B: the contract never finished (no EXPO_CONTRACT_DONE)"
for name in classes emitter subclass uuidv4 uuidv5-shape uuidv5-bad-namespace-throws modules \
            expo-go-absent globals dl-a-no-md5 dl-b-md5 dl-c-cache-hit dl-d-rejects-coded \
            dl-e-stale-refetch dl-f-file-passthrough dl-g-rejects-escape \
            constants fetch-hello fetch-status fetch-post fetch-redirect-follow fetch-redirect-manual \
            fetch-redirect-error fetch-abort fetch-stream fetch-global; do
  grep -q "^\[js\] EXPO_CONTRACT $name PASS" "$LOG" || fail "B: check '$name' did not PASS"
done
echo "$DONE" | grep -q ' fail=0$' || fail "B: $DONE"
N="$(echo "$DONE" | sed -E 's/.*pass=([0-9]+).*/\1/')"
[ "$N" -eq 26 ] || fail "B: expected 26 checks, the fixture ran $N"

WANT_V5="$(python3 "$CHECK" uuid5dns www.example.com)"
GOT_V5="$(sed -n 's/^\[js\] EXPO_UUIDV5 //p' "$LOG")"
[ "$GOT_V5" = "$WANT_V5" ] || fail "B: uuidv5 = '$GOT_V5', Python's uuid5 = '$WANT_V5'"
grep -q "^\[js\] EXPO_DIRS cacheDir=$WORK/cache documentsDir=$WORK/docs\$" "$LOG" \
  || fail "B: expo.cacheDir/documentsDir do not follow RNI_CACHE_DIR/RNI_DOCUMENTS_DIR"

dl_path() {  # dl_path <case> -> local path the engine resolved (file:// stripped)
  sed -n "s/^\[js\] EXPO_DL $1 ok file:\/\///p" "$LOG"
}
same_bytes() { cmp -s "$1" "$2"; }
MD5_URL_A="$(python3 "$CHECK" md5str "$BASE/a.bin")"
PA="$(dl_path a)"; [ "$PA" = "$WORK/cache/ExponentAsset-$MD5_URL_A.bin" ] \
  || fail "B: case a resolved '$PA', expected the cache file named by MD5(url)=$MD5_URL_A"
same_bytes "$PA" "$SRV/a.bin" || fail "B: case a: cached bytes differ from what the server sent"
PB="$(dl_path b)"; same_bytes "$PB" "$SRV/b.bin" || fail "B: case b: '$PB' does not hold the served bytes"
PC="$(dl_path c)"; same_bytes "$PC" "$WORK/c-content.bin" || fail "B: case c: cache hit file changed"
PE="$(dl_path e)"; same_bytes "$PE" "$SRV/e.bin" || fail "B: case e: stale cache file was not refetched"
grep -q '^\[js\] EXPO_DL d err ERR_UNABLE_TO_DOWNLOAD_ASSET$' "$LOG" || fail "B: case d did not reject with ERR_UNABLE_TO_DOWNLOAD_ASSET"
[ ! -e "$WORK/escape.bin" ] && [ -z "$(find "$WORK" -maxdepth 1 -name 'escape*')" ] || fail "B: case g wrote outside the cache dir"
PX="$(python3 "$CHECK" ppm "$WORK/contract.ppm")"
echo "   pixels: $PX"
echo "$PX" | grep -q 'green_corner=1' || fail "B: the contract screen is not green (the app saw a failure)"
grep -q '^GET /fetch/hello x-rni-req=sc44 ' "$WORK/reqlog" || fail "B: the server never saw expo/fetch's X-Rni-Req header"
grep -q '^POST /fetch/echo x-rni-req=- body=ping-body$' "$WORK/reqlog" || fail "B: the server never saw the POST body"
[ "$(grep -c '^GET /fetch/hello ' "$WORK/reqlog")" -ge 3 ] || fail "B: the redirect was not followed to /fetch/hello"
echo "   B ok: 26/26 checks, uuidv5 = Python, 4 cache files verified on disk, $(grep -c /fetch/ "$WORK/reqlog") fetch requests at the server"

echo "== C. --list-modules =="
LOG="$WORK/list.log"
set +e; "$BIN" --list-modules > "$LOG" 2>&1; RC=$?; set -e
[ "$RC" -eq 0 ] || { tail -10 "$LOG" >&2; fail "C: --list-modules exited $RC"; }
sed 's/^\[js\] //' "$LOG" > "$WORK/manifest"
grep -q '^expo_module=ExpoAsset methods=downloadAsync$' "$WORK/manifest" \
  || { grep expo_module "$WORK/manifest" >&2 || true; fail "C: ExpoAsset missing from the manifest"; }
grep -q '^expo_module=ExpoFetchModule methods=NativeRequest,NativeResponse,unstable_createBlobData$' "$WORK/manifest" \
  || { grep expo_module "$WORK/manifest" >&2 || true; fail "C: ExpoFetchModule missing from the manifest"; }
grep -qE '^expo_module=ExponentConstants methods=.*executionEnvironment' "$WORK/manifest" \
  || { grep expo_module "$WORK/manifest" >&2 || true; fail "C: ExponentConstants missing from the manifest"; }
for m in ExpoAsset ExpoFetchModule ExponentConstants; do
  ! grep -q "^module=$m" "$WORK/manifest" || fail "C: $m listed as a TurboModule"
done
grep -q '^MODULE_MANIFEST_END$' "$WORK/manifest" || fail "C: manifest truncated"
echo "   C ok: expo_module= ExpoAsset, ExpoFetchModule, ExponentConstants"

echo "EXPO_HOST_PASS"
