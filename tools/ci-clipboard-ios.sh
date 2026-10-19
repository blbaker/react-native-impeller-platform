#!/usr/bin/env bash
# iOS Phase 1 / Task 1.5 gate: a clipboard write through ClipboardBridge
# reaches the iOS pasteboard (ClipboardIOS.mm, UIPasteboard backend).
# The gate seeds the simulator pasteboard with a stale value from outside the
# app (simctl pbcopy), launches the test host (--test=clipboard) with a fresh
# value, which it writes from a background thread through bridge.postToMain
# (the JS-thread path ClipboardModule::setString takes).
# Arms (each failure prints `IOS_CLIPBOARD_GATE FAIL <arm>: ...`):
#   W  the write task ran (write_done) and UIPasteboard.changeCount moved
#   O  the pasteboard read from OUTSIDE the app (simctl pbpaste) is the new
#      value: the write reached the OS, not just the bridge
#   D  UIPasteboard.general.string read directly in the app (bypassing the
#      bridge) is the new value
#   B  the bridge's own read (getSystemNow via postToMain) is the new value
# Pass line: IOS_CLIPBOARD_PASS (os_read=<value>). Mutants:
# tools/mutation-verify-clipboard-ios.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
ios_begin clipboard
FAILS=()
bad() { echo "IOS_CLIPBOARD_GATE FAIL $1: $2"; FAILS+=("$1"); }
NONCE="rni-clip-$(date +%s)-$$"
STALE="stale-$$"

ios_build_testhost || { echo "IOS_CLIPBOARD_FAIL (build)"; exit 1; }
ios_sim_up || { echo "IOS_CLIPBOARD_FAIL (simulator)"; exit 1; }
printf '%s' "$STALE" | xcrun simctl pbcopy "$IOS_UDID"
[ "$(xcrun simctl pbpaste "$IOS_UDID")" = "$STALE" ] || bad O "could not seed the pasteboard"
LOG="$IOS_WORK/app.log"
ios_launch "$LOG" clipboard "--clip=$NONCE" || { echo "IOS_CLIPBOARD_FAIL (launch)"; exit 1; }
ios_wait_log "$LOG" 'clipboard write_done ' 30 || bad W "the write task never ran"
ios_wait_log "$LOG" 'clipboard (direct_read|bridge_read)=' 10
ios_wait_log "$LOG" 'clipboard bridge_read=' 5
OS_READ="$(xcrun simctl pbpaste "$IOS_UDID")"
cat "$LOG"
ios_keep "$LOG"

BEFORE=$(ios_kv "$LOG" 'change_count_before=' change_count_before)
AFTER=$(sed -nE 's/.*change_count_after=([0-9]+).*/\1/p' "$LOG" | head -1)
[ -n "$AFTER" ] && [ "$AFTER" != "$BEFORE" ] || bad W "changeCount did not move ($BEFORE -> ${AFTER:-none})"
echo "outside read (simctl pbpaste): $OS_READ"
[ "$OS_READ" = "$NONCE" ] || bad O "the OS pasteboard holds '$OS_READ', not '$NONCE'"
grep -q "clipboard direct_read=$NONCE\$" "$LOG" || bad D "$(grep -m1 'direct_read=' "$LOG" || echo 'no direct read')"
grep -q "clipboard bridge_read=$NONCE\$" "$LOG" || bad B "$(grep -m1 'bridge_read=' "$LOG" || echo 'no bridge read')"
[ "${#FAILS[@]}" = 0 ] || { echo "IOS_CLIPBOARD_FAIL (${FAILS[*]})"; exit 1; }
echo "IOS_CLIPBOARD_PASS (os_read=$OS_READ)"
