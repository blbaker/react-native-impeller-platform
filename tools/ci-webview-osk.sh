#!/usr/bin/env bash
# App-drawn keyboard gate: ImpellerWebView.sendText / sendKey and the
# editableFocus event, on rn-impeller's WPE web view (linux, real X taps).
#
# Node-free: committed bundle fixtures/webview-osk/prebuilt + staged engine (RNI_BIN).
# Needs docker + a WPE helper image (default: Debian sid's WebKit, the one the board
# tarball ships: bash tools/webhelper-debian-x64.sh image && ... build), Xvfb, and
# python-xlib (~/.cache/rni/xtest-venv).
#
# One windowed run under a private Xvfb. tools/webview_osk_drive.py taps with XTEST;
# the fixture app types from onEditableFocus. tools/webview_osk_check.py then reads
# the log tap by tap:
#   tap the text field       editableFocus focused=true isPassword=false (prop AND the
#                            raw impellerWebViewEvent); sendText 'abc' is ONE commit (a
#                            single beforeinput, no key events); sendKey Backspace is a
#                            real keydown; value 'ab' read back with injectJavaScript
#                            into document.title, then navState; sendText 'é漢' lands
#                            verbatim; sendKey('NoSuchKey') throws
#   tap the password field   focused=true isPassword=true; sendText 'pw1' lands
#   tap the page outside     focused=false
#   tap the text field again sendKey Enter submits the form (the page sets its title)
#   tap the app's keys t e s t  RN views in the bar, OUTSIDE the web view, with
#                            setKeepFocus(true): each press logs webview_input
#                            keep_focus, reaches the key's onPress, and its sendText
#                            lands ('abé漢test'); no editableFocus, no page blur and no
#                            helper "no editable has input focus" between the keys
#   5 x tap Done, tap #t     the app's Done key (RN, outside; the press keeps focus) calls
#                            setKeepFocus(false), which blurs the view (focused=false,
#                            engine `keep_focus ... on=0 blur=1`); a tap on the SAME
#                            field then reports focused=true again, so the console can
#                            reopen its keyboard. Before the fifth tap a physical key
#                            reaches RN, not the blurred page
#   tap the RN bar           with the flag off: focused=false (an outside press blurs,
#                            as before the flag existed)
#   and the helper exits cleanly (webview_check.py helper-exit).
# Mutants: tools/mutation-verify-webview-osk.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. tools/lib/host-window.sh
fail() { echo "WEBVIEW_OSK_FAIL: $*" >&2; exit 1; }
[ "$(rni_host)" = linux ] || fail "linux only"
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
BUNDLE="$ROOT/fixtures/webview-osk/prebuilt/webview-osk.bundle"
XPY="${RNI_XTEST_PY:-$HOME/.cache/rni/xtest-venv/bin/python}"
[ -n "${RNI_WEBHELPER:-}" ] || eval "$(bash tools/webhelper-debian-x64.sh env)"
export RNI_WEBHELPER_EXIT_MS="${RNI_WEBHELPER_EXIT_MS:-20000}"
[ -x "$BIN" ] || fail "no engine at $BIN"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
[ -x "$XPY" ] || fail "no python-xlib venv at $XPY"
echo "engine: $BIN ($(sha256sum "$BIN" | cut -c1-12)) helper: $RNI_WEBHELPER ${RNI_WPE_IMAGE:-}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-webview-osk.XXXXXX")"
SRV=""
cleanup() {
  [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; }
  [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
python3 tools/webview_server.py "$PORT" "$ROOT/fixtures/webview-osk/pages" "$WORK/req.log" &
SRV=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/osk.html" && break; sleep 0.1; done
curl -s -o /dev/null "http://127.0.0.1:$PORT/osk.html" || fail "harness: fixture server not reachable"

LOG="$WORK/osk.log"
cat > "$WORK/run.sh" <<EOF
cd "$(dirname "$BIN")"
"$BIN" --window --scale 1 --width 600 --height 420 --probe-banner off --supersample-rnsvg 0 \\
  --app-name WebViewOskGate --bundle "$BUNDLE" \\
  --initial-url "webview-osk://run?base=http://127.0.0.1:$PORT" \\
  --idle-skip --idle-run-sec 70 >> "$LOG" 2>&1 &
EPID=\$!
"$XPY" "$ROOT/tools/webview_osk_drive.py" "$LOG" >> "$LOG" 2>&1 || true
wait \$EPID; echo "ENGINE_RC=\$?" >> "$LOG"
EOF
: > "$LOG"
RNI_WEBVIEW_DATA_DIR="$WORK/data" timeout 150 xvfb-run -a -s "-screen 0 1280x1024x24" bash "$WORK/run.sh" || true
grep -q "ENGINE_RC=" "$LOG" || fail "engine run did not finish (timeout)"
python3 tools/webview_osk_check.py "$LOG" \
  || { grep -E 'OSK_DRIVE|WVAPP|WVPAGE|editableFocus|unknown message' "$LOG" | tail -40 >&2; exit 1; }
python3 tools/webview_check.py helper-exit "$LOG" osk
echo "WEBVIEW_OSK_GATE_PASS"
