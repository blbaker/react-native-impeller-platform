#!/usr/bin/env bash
# ci-crypto — ENG-31: globalThis.crypto.getRandomValues on the OS CSPRNG
# (engine/modules/CryptoGlobal.{h,cpp}).
#
# Node-free: renders the committed bundles (tools/build-fixture-bundle.sh
# eng31-crypto CryptoContract / eng31-relay-probe probe), so the Mac runs it
# with RNI_BIN=<darwin binary> and python3 only.
#
#   A. Contract (fixtures/eng31-crypto): 15 named checks must PASS -- reading
#      crypto never throws; same array returned; a 65536-byte draw has every
#      4 KB chunk non-zero, all 256 byte values, chi2 < 400, and differs from a
#      second draw; 65537 bytes -> QuotaExceededError with the array untouched;
#      the quota counts BYTES (Uint32Array 16384 ok, 16385 throws); a view's
#      byteOffset is respected (neighbouring bytes stay zero); every integer
#      TypedArray kind fills; Float32/64 and DataView -> TypeMismatchError;
#      non-views -> TypeError; an object faking a Uint8Array is refused; a
#      patched %TypedArray% byteLength getter cannot steer the fill. The
#      screen must be green.
#   B. The macOS tester's relay probe, verbatim (fixtures/eng31-relay-probe),
#      against a stdlib ws echo server on 127.0.0.1:8797: RELAY_NOTES must read
#      crypto-bare=object crypto=object grv=function grv-call=ok and ws-open/
#      ws-text/ws-binary=ok settled=events, and the red SUBJECT band must paint
#      (it only does when the probe's own verdict is OK).
#   C. Two separate processes draw different first 32 bytes (a fixed-seed
#      generator passes A and B and fails here).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
cd "$(dirname "$0")/.."
ROOT="$PWD"
CHECK="$ROOT/tools/crypto_check.py"
CONTRACT="$ROOT/fixtures/eng31-crypto/prebuilt/eng31-crypto.bundle"
RELAY="$ROOT/fixtures/eng31-relay-probe/prebuilt/eng31-relay-probe.bundle"
fail() { echo "CRYPTO_GATE_FAIL: $*" >&2; exit 1; }
OS="$(uname -s)"
for b in "$CONTRACT" "$RELAY"; do
  [ -s "$b" ] || fail "no committed bundle $b (tools/build-fixture-bundle.sh)"
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
[ -x "$BIN" ] || fail "no engine binary at $BIN (tools/engine-build.sh, or set RNI_BIN)"
echo "engine: $BIN"

WORK="$(mktemp -d)"
SRV_PID=""
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true
  rni_kill_own
  [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

render() {  # render <bundle> <app> <log> <ppm>
  set +e
  "$BIN" --bundle "$1" --app-name "$2" --headless --width 960 --height 540 \
    --probe-banner off --supersample-rnsvg 0 --screenshot "$4" > "$3" 2>&1
  local _rc=$?
  set -e
  return $_rc
}
js_ok() {  # js_ok <log> <arm>
  if grep -q '^\[js-error\]' "$1"; then
    grep '^\[js-error\]' "$1" | head -3 >&2
    fail "$2: [js-error] in the log"
  fi
  grep -q '^RN_IMPELLER_RENDER_OK' "$1" || { tail -15 "$1" >&2; fail "$2: no RN_IMPELLER_RENDER_OK"; }
  grep -q 'scene_nodes=[1-9]' "$1" || fail "$2: scene_nodes=0 (nothing mounted)"
}

CHECKS="bare-read shape returns-same-array u8-32-nonzero-differ quota-65536-full quota-65537-throws
quota-counts-bytes offset-respected integer-types float-rejected dataview-rejected non-view-rejected
spoof-rejected intrinsics-captured zero-length"
contract_run() {  # contract_run <n>
  local _log="$WORK/contract-$1.log" _ppm="$WORK/contract-$1.ppm"
  render "$CONTRACT" CryptoContract "$_log" "$_ppm" || { tail -20 "$_log" >&2; fail "A$1: engine exited non-zero"; }
  js_ok "$_log" "A$1"
  { grep -E '^\[js\] CRYPTO_' "$_log" || true; } | sed 's/^\[js\] /   /'
  local _name _n=0
  for _name in $CHECKS; do
    _n=$((_n + 1))
    grep -q "^\[js\] CRYPTO_CONTRACT $_name PASS" "$_log" || fail "A$1: check '$_name' did not PASS"
  done
  grep -q "^\[js\] CRYPTO_CONTRACT_DONE pass=$_n fail=0\$" "$_log" \
    || fail "A$1: $(grep -m1 CRYPTO_CONTRACT_DONE "$_log" || echo 'no DONE line'), wanted pass=$_n fail=0"
  local _px; _px="$(python3 "$CHECK" ppm "$_ppm")"
  echo "   pixels: $_px"
  python3 -c "import sys; g,r,t=[int(x.split('=')[1]) for x in '$_px'.split()]; sys.exit(0 if g > 0.9*t and r == 0 else 1)" \
    || fail "A$1: the contract screen is not green ($_px)"
}

echo "== A. contract =="
contract_run 1
echo "   A ok: 15/15 checks, green screen"

echo "== B. the Mac's relay probe, verbatim, vs a ws echo on 8797 =="
python3 "$CHECK" ws-echo 8797 "$WORK/ready" > "$WORK/ws.log" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 100); do [ -s "$WORK/ready" ] && break; sleep 0.05; done
grep -q '^LISTENING' "$WORK/ready" 2>/dev/null || fail "B: echo server: $(cat "$WORK/ready" 2>/dev/null || echo 'never started') (is 8797 taken?)"
LOG="$WORK/relay.log"
render "$RELAY" probe "$LOG" "$WORK/relay.ppm" || { tail -20 "$LOG" >&2; fail "B: engine exited non-zero"; }
js_ok "$LOG" B
NOTES="$(sed -n 's/^\[js\] RELAY_NOTES //p' "$LOG" | tail -1)"
echo "   RELAY_NOTES $NOTES"
[ -n "$NOTES" ] || fail "B: the probe never printed RELAY_NOTES"
for kv in crypto-bare=object crypto=object grv=function grv-call=ok ws-open=ok ws-text=ok ws-binary=ok settled=events; do
  case " $NOTES " in *" $kv "*) ;; *) fail "B: RELAY_NOTES lacks '$kv'";; esac
done
grep -q 'ws-echo: opcode=1 ' "$WORK/ws.log" && grep -q 'ws-echo: opcode=2 ' "$WORK/ws.log" \
  || fail "B: the echo server never saw a text and a binary frame"
PX="$(python3 "$CHECK" ppm "$WORK/relay.ppm")"
echo "   pixels: $PX"
GREEN="$(echo "$PX" | sed -E 's/.*green=([0-9]+).*/\1/')"
RED="$(echo "$PX" | sed -E 's/.*red=([0-9]+).*/\1/')"
[ "$GREEN" -ge 18000 ] || fail "B: CONTROL band missing (green=$GREEN): harness broken"
[ "$RED" -ge 18000 ] || fail "B: SUBJECT band not red (red=$RED): the probe's verdict was not OK"
echo "   B ok: probe verdict OK, red=$RED green=$GREEN"

echo "== C. a second process draws different bytes =="
contract_run 2
F1="$(sed -n 's/^\[js\] CRYPTO_FIRST32 //p' "$WORK/contract-1.log")"
F2="$(sed -n 's/^\[js\] CRYPTO_FIRST32 //p' "$WORK/contract-2.log")"
[ ${#F1} -eq 64 ] && [ ${#F2} -eq 64 ] || fail "C: CRYPTO_FIRST32 missing ('$F1' / '$F2')"
[ "$F1" != "$F2" ] || fail "C: two processes drew the same first 32 bytes ($F1): seeded, not OS entropy"
echo "   C ok: $F1 != $F2"

echo "CRYPTO_PASS"
