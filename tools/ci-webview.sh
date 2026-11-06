#!/usr/bin/env bash
# web view gate: react-native-webview's <WebView> on rn-impeller (WPE).
#
# Node-free: committed bundle fixtures/webview/prebuilt + staged engine (RNI_BIN).
# Needs docker + the WPE image on WSL (tools/webhelper-docker.sh is the default
# RNI_WEBHELPER), Xvfb, and python-xlib (~/.cache/rni/xtest-venv).
#
#   static    the bundle imports 'react-native-webview' by name and got the
#             engine's shim (marker), never the real package's RNCWebView.
#   main      one windowed run under a private Xvfb, REAL X input (XTEST):
#             pixels of the page composited under an RN bar (X server readback);
#             hover enter/leave; a click at the right page coordinate (left
#             button = one touch sequence, WebKit taps it into a click); typing
#             "abc" + Backspace = "ab"; a drag = ONE touch sequence (>=5 moves,
#             dx~220); wheel scrolls the page (and the pixels move);
#             injectedJavaScript after every page + BeforeContentLoaded before
#             the page's script; source.headers on the top-level request ONLY;
#             loadStart/load/loadEnd/navState in order; target=_blank opens in
#             the same view; goBack (canGoForward), reload, stopLoading (< 2 s on
#             an 8 s response, no onLoad), onError with a code.
#   cookies   a 2nd process with the same data dir still has the cookie
#             (sign-in survives restart); clearWebsiteData() wipes it.
#   nohelper  NEGATIVE: a helper that cannot start reaches onError, clean exit.
#   (every run with a real helper) the HELPER exits cleanly too: each destroyed
#             view reached it, the engine reaped it with code 0, no glibc abort
#             (webview_check.py helper-exit).
#   eme       (opt-in, needs network + a CDM) the Shaka sintel-widevine asset, licence
#             from cwip-shaka-proxy: WebKit EME -> libocdm.so (OpenCDM shim) ->
#             libwidevinecdm.so. Verdict from 8 ENGINE readbacks of the player rect
#             (rn-impeller --screenshot-series, 2 s apart; tools/webview_eme_series.py)
#             by tools/webview_eme_check.py, the same rules as the arm64 arm.
#   eme-nocdm / eme-skipdecrypt  NEGATIVES on the same binary: must be NOT_PLAYING
#             (no CDM = hole, shaka 6006; shim skips decrypt = grey mush, clock runs).
#   ARMS="eme eme-nocdm eme-skipdecrypt" bash tools/ci-webview.sh
# Mutants: tools/mutation-verify-webview.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. tools/lib/host-window.sh
fail() { echo "WEBVIEW_FAIL: $*" >&2; exit 1; }
[ "$(rni_host)" = linux ] || fail "linux only (darwin backend not decided yet)"
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
BUNDLE="$ROOT/fixtures/webview/prebuilt/webview.bundle"
XPY="${RNI_XTEST_PY:-$HOME/.cache/rni/xtest-venv/bin/python}"
export RNI_WEBHELPER="${RNI_WEBHELPER:-$ROOT/tools/webhelper-docker.sh}"
# Engine exit waits this long for the helper (docker --rm teardown included).
export RNI_WEBHELPER_EXIT_MS="${RNI_WEBHELPER_EXIT_MS:-20000}"
ARMS="${ARMS:-static main cookies nohelper}"
SKIPPED=""
[ -x "$BIN" ] || fail "no engine at $BIN"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
[ -x "$XPY" ] || fail "no python-xlib venv at $XPY"
echo "engine: $BIN ($(sha256sum "$BIN" | cut -c1-12)) helper: $RNI_WEBHELPER"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-webview.XXXXXX")"
SRV=""
cleanup() {
  [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; }
  [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
CLOSED="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"  # refused: onError arm
python3 tools/webview_server.py "$PORT" "$ROOT/fixtures/webview/pages" "$WORK/req.log" &
SRV=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/b.html" && break; sleep 0.1; done
curl -s -o /dev/null "http://127.0.0.1:$PORT/b.html" || fail "harness: fixture server not reachable"
: > "$WORK/req.log"  # drop the readiness probe

# run <tag> <mode> <secs> [driver.py]: one windowed engine under a private Xvfb.
# RUN_EXTRA (global): extra engine flags for this run.
RUN_EXTRA=""
run() {
  local tag="$1" mode="$2" secs="$3" drive="${4:-}"
  [ "$drive" = drive ] && drive=webview_xdrive.py
  cat > "$WORK/$tag.sh" <<EOF
cd "$(dirname "$BIN")"
"$BIN" --window --scale 1 --width 600 --height 420 --probe-banner off --supersample-rnsvg 0 \\
  --app-name WebViewGate --bundle "$BUNDLE" \\
  --initial-url "webview://run?base=http://127.0.0.1:$PORT&mode=$mode&closed=$CLOSED" \\
  --idle-skip --idle-run-sec $secs $RUN_EXTRA >> "$WORK/$tag.log" 2>&1 &
EPID=\$!
if [ -n "$drive" ]; then "$XPY" "$ROOT/tools/$drive" "$WORK/$tag.log" "$WORK" >> "$WORK/$tag.log" 2>&1 || true; fi
wait \$EPID; echo "ENGINE_RC=\$?" >> "$WORK/$tag.log"
EOF
  : > "$WORK/$tag.log"
  RNI_WEBVIEW_DATA_DIR="$WORK/data" timeout $((secs + 60)) xvfb-run -a -s "-screen 0 1280x1024x24" bash "$WORK/$tag.sh" || true
  grep -q "ENGINE_RC=" "$WORK/$tag.log" || fail "$tag: engine run did not finish (timeout)"
  # The HELPER must end cleanly too (code 0, no abort): the engine reaps it at exit.
  python3 tools/webview_check.py helper-exit "$WORK/$tag.log" "$tag"
}

for arm in $ARMS; do
  case "$arm" in
    static)
      grep -q "rn-impeller-webview-shim" "$BUNDLE" || fail "static: bundle lacks the engine WebView shim"
      ! grep -q "RNCWebView" "$BUNDLE" || fail "static: bundle carries the real package's RNCWebView"
      echo "WEBVIEW static ok: react-native-webview resolved to the engine shim" ;;
    main)
      run main main 45 drive
      python3 tools/webview_check.py main "$WORK/main.log" "$WORK/req.log" "$WORK/shot-a.ppm" "$WORK/shot-scrolled.ppm" \
        || { grep -E 'DRIVE|WVPAGE|WVAPP' "$WORK/main.log" | tail -25 >&2; exit 1; } ;;
    cookies)
      [ -d "$WORK/data" ] || run seed main 45 drive  # cookies arm alone: seed the jar first
      run cookie-read cookie-read 12
      python3 tools/webview_check.py cookie "$WORK/cookie-read.log" sess=abc123
      run cookie-clear cookie-clear 12
      python3 tools/webview_check.py cookie "$WORK/cookie-clear.log" none ;;
    nohelper)
      : > "$WORK/nohelper.log"
      RNI_WEBHELPER=/bin/false RNI_WEBVIEW_DATA_DIR="$WORK/nohelper-data" \
        timeout 60 xvfb-run -a -s "-screen 0 1280x1024x24" bash -c "cd '$(dirname "$BIN")' && '$BIN' --window --scale 1 --width 600 --height 420 --probe-banner off --app-name WebViewGate --bundle '$BUNDLE' --initial-url 'webview://run?base=http://127.0.0.1:$PORT&mode=main' --idle-skip --idle-run-sec 6 >> '$WORK/nohelper.log' 2>&1; echo ENGINE_RC=\$? >> '$WORK/nohelper.log'" || true
      python3 tools/webview_check.py nohelper "$WORK/nohelper.log" ;;
    eme|eme-nocdm|eme-skipdecrypt)
      # EME end to end: page EME -> WebKit -> libocdm.so (OpenCDM shim) -> the CDM.
      # eme-nocdm and eme-skipdecrypt are NEGATIVE controls: same page, same
      # binary, no CDM / a shim that reports success without decrypting.
      CDM="${RNI_WIDEVINE_CDM:-$HOME/projects/wv-cdm-probe/cdm/x/_platform_specific/linux_x64/libwidevinecdm.so}"
      if [ "$arm" != eme-nocdm ] && [ ! -f "$CDM" ]; then
        echo "WEBVIEW $arm SKIPPED: no CDM at $CDM (not a pass)"; SKIPPED="$SKIPPED $arm"; continue
      fi
      if [ "$arm" = eme-nocdm ]; then unset RNI_WIDEVINE_CDM; else export RNI_WIDEVINE_CDM="$CDM"; fi
      if [ "$arm" = eme-skipdecrypt ]; then export OCDM_SHIM_TEST_SKIP_DECRYPT=1; else unset OCDM_SHIM_TEST_SKIP_DECRYPT; fi
      RUN_EXTRA="--screenshot $WORK/$arm-shot.ppm --screenshot-when-file $WORK/$arm-shot.go --screenshot-series 8"
      run "$arm" eme 75 webview_eme_series.py
      RUN_EXTRA=""
      unset RNI_WIDEVINE_CDM OCDM_SHIM_TEST_SKIP_DECRYPT
      mkdir -p "$WORK/$arm.d" && cp "$WORK/$arm.log" "$WORK/$arm.d/engine.out"
      EME_CHECK_TAG=WEBVIEW python3 tools/webview_eme_check.py "$WORK/$arm.d" \
        "$([ "$arm" = eme ] && echo PLAYING || echo NOT_PLAYING)" off - \
        || { grep -E 'EME_SERIES|WVEME (fail|keysystem)' "$WORK/$arm.log" | tail -5 >&2; exit 1; } ;;
    *) fail "unknown arm $arm" ;;
  esac
done
echo "WEBVIEW_GATE_PASS arms=\"$ARMS\"${SKIPPED:+ SKIPPED:$SKIPPED}"
