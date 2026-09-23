#!/usr/bin/env bash
# ENG-01b item 5 GATE: the caret BLINK decision.
#
# The caret is a blinking bar -- on for ~500 ms, off for ~500 ms -- and it must
# become VISIBLE AGAIN on every keystroke, so a burst of typing never leaves the
# insertion point behind an off phase. That "reset to visible on edit" is the
# half a free-running `(now/500)%2` blink gets wrong.
#
# ⛔ WHY THIS GATES A PURE PREDICATE, NOT A SCREENSHOT.
# Whether the caret paints this frame is a function of ONE input: milliseconds
# since the last caret reset (SceneGraph::tiCaretResetAt_, set on focus, click
# and every keystroke). The wall clock, the frame loop and Impeller only supply
# that number and draw the result. A screenshot cannot reliably gate a blink:
# capture during an on phase and a BROKEN blink (never resets, free-running)
# passes just as happily as a correct one -- the bug is that typing during an
# off phase hides the caret, and a single frame cannot see "off at the wrong
# moment". So the rule is factored into CaretBlink.h::caretVisible and exercised
# directly via --test-caret-blink, exactly as ci-p*/retina gate DeriveWindowPointScale
# through --test-pointscale on a host with no Retina display.
#
# The engine wires caretVisible into paintNode's caret branch and resets the
# phase in setTextInputFocus/setTextInputEdit; ci-textedit.sh proves the edit
# path those resets hang off still works end to end.
set -euo pipefail
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"

fail() { echo "CARET_GATE_FAIL: $*" >&2; exit 1; }

bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH" > /dev/null || fail "engine build failed"
RESOLVED="$ROOT/packages-engine/engine-${RNI_TRIPLE}/bin/rn-impeller"
[ -x "$RESOLVED" ] || fail "no engine binary at $RESOLVED"

echo "== 1. run the pure caret-blink self-test =="
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
set +e
"$RESOLVED" --test-caret-blink > "$LOG" 2>&1
rc=$?
set -e
sed 's/^/   /' "$LOG"
[ "$rc" -eq 0 ] || fail "--test-caret-blink exited $rc"

echo "== 2. assert the load-bearing properties are present and pass =="
# The just-typed instant MUST be on: this is the property that makes typing
# during an off phase impossible. A build that dropped the reset would compute
# ms>0 at t=0 and this line could read off.
grep -Eq 'just typed \(t=0\).*-> on \(want on\) ok' "$LOG" \
  || fail "the just-typed (t=0) case is not ON -- a keystroke would land next to an invisible caret"
# The phase actually flips: on at 499, off at 500. A stuck-on caret (never
# blinks) would read on at 500 and fail here.
grep -Eq 'last ms of on-phase.*ms=499 .*-> on \(want on\) ok'   "$LOG" || fail "caret not on at 499ms -- blink boundary wrong"
grep -Eq 'first ms of off-phase.*ms=500 .*-> off \(want off\) ok' "$LOG" || fail "caret not off at 500ms -- caret never blinks off"
# And back on after a full period, proving it oscillates rather than latching.
grep -Eq 'back on after a full period.*ms=1000 .*-> on \(want on\) ok' "$LOG" || fail "caret not back on at 1000ms -- blink does not oscillate"
# Clock skew must not hide it.
grep -Eq 'clock skew.*-> on \(want on\) ok' "$LOG" || fail "negative elapsed hid the caret -- a backward clock blanks the insertion point"

# The self-test's own verdict line, as the final backstop.
grep -Eq 'caret-blink self-test: PASS \(0 failures\)' "$LOG" || fail "self-test did not report PASS"
echo "   OK: t=0 on, flips at 500ms, oscillates, survives clock skew"

echo "CARET_GATE_PASS (blink ~${RNI_TRIPLE:+}500ms, visible on every keystroke)"
