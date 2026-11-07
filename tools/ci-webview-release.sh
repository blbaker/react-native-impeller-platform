#!/usr/bin/env bash
# memory gate: a destroyed web view's WPEWebProcess EXITS.
#
# Before the fix, WebKit's WebProcessCache kept the closed page's web process
# alive for 5 minutes (WEBKIT_CACHE_MODEL_WEB_BROWSER, the default). On the
# the board that held ~300 MB PSS after the streaming tile unmounted.
#
# tools/webview_release_probe.py plays the engine side of the helper protocol
# against the REAL helper + Debian WPE 2.54 (the board's WebKit): two views on
# two sites, destroy one (its process must exit, the other view must keep
# loading), destroy the other (no web process left). See the probe for steps.
#
#   eval "$(bash tools/webhelper-debian-x64.sh env)"; bash tools/ci-webview-release.sh
#   RNI_WEBHELPER_DIR=<dir with an old rni-webhelper> ... -> must FAIL (control)
# Mutants: tools/mutation-verify-webview-release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail() { echo "WEBVIEW_RELEASE_FAIL: $*" >&2; exit 1; }
[ -n "${RNI_WEBHELPER:-}" ] || eval "$(bash tools/webhelper-debian-x64.sh env)"
export RNI_WEBHELPER
[ -x "${RNI_WEBHELPER_DIR:-}/rni-webhelper" ] || fail "no helper at ${RNI_WEBHELPER_DIR:-?}/rni-webhelper (tools/webhelper-debian-x64.sh build)"
echo "helper: $RNI_WEBHELPER_DIR/rni-webhelper ($(sha256sum "$RNI_WEBHELPER_DIR/rni-webhelper" | cut -c1-12))"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-webview-release.XXXXXX")"
SRV=""
cleanup() {
  [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; }
  [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
python3 tools/webview_server.py "$PORT" "$ROOT/fixtures/webview/pages" "$WORK/req.log" &
SRV=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/b.html" && break; sleep 0.1; done
curl -s -o /dev/null "http://127.0.0.1:$PORT/b.html" || fail "harness: fixture server not reachable"

# 127.0.0.1 and localhost are two sites, so WebKit gives each view its own process.
set +e
python3 tools/webview_release_probe.py --helper "$RNI_WEBHELPER" --work "$WORK/probe" \
  --url-a "http://127.0.0.1:$PORT/a.html" --url-b "http://localhost:$PORT/b.html" \
  --settle-s "${RELEASE_SETTLE_S:-8}" | tee "$WORK/probe.log"
rc=${PIPESTATUS[0]}
set -e
grep -E "cache_model|view [0-9]+ (created|destroyed)" "$WORK/probe/helper.out" || true
[ "$rc" = 0 ] || fail "probe rc=$rc ($(grep -o 'WEBVIEW_RELEASE_FAIL.*' "$WORK/probe.log" | head -1))"
grep -q "rni-webhelper: cache_model=document_browser" "$WORK/probe/helper.out" \
  || fail "helper did not report cache_model=document_browser"
echo "WEBVIEW_RELEASE_GATE_PASS"
