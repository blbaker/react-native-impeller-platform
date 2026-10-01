#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-clipboard.sh (desktop-input-gap item 5).
#
#   M1  paste ignores the selection (inserts at the caret, leaves the
#       selected text in place) -- engine/fabric/FabricHost.cpp
#   M2  setString never reaches the system (the main-thread set is dropped)
#       -- engine/modules/ClipboardModule.h
#   M3  no newline flattening on paste -- engine/fabric/FabricHost.cpp
#   M4  cut copies but does not erase the selection -- engine/fabric/FabricHost.cpp
#
# Each mutant is checked against which arm it ACTUALLY trips (not merely the
# arm it was designed for) before being trusted:
#   M1 only changes behaviour when Paste has a live selection -- that is arm
#      d alone (b/c/e/f paste into an EMPTY field).
#   M2 breaks the JS Clipboard.setString() path -- arm a (the JS round trip)
#      is both the first arm to use it AND would also break arm e's
#      "setnewline" button, so the ERE lists both failure messages.
#   M3 only changes behaviour when the clipboard content contains a CR or LF
#      -- that is arm e alone.
#   M4 only changes Cut's erase -- that is arm c alone (no other arm cuts).
set -euo pipefail
cd "$(dirname "$0")/.."
FH="engine/fabric/FabricHost.cpp"
CM="engine/modules/ClipboardModule.h"

BAK="$(mktemp -d)"
cp "$FH" "$BAK/FabricHost.cpp"
cp "$CM" "$BAK/ClipboardModule.h"
restore() { cp "$BAK/FabricHost.cpp" "$FH"; cp "$BAK/ClipboardModule.h" "$CM"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$FH" "$CM" && fail "mutant residue already in the tree -- restore it first (git diff)"
grep -q "KeyAction::Paste" "$FH" || fail "the fix is NOT in the tree (no KeyAction::Paste) -- a passing gate here would be blind"
grep -q "FlattenNewlinesForSingleLine" "$FH" || fail "the fix is NOT in the tree (no newline flattening) -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-clipboard.sh > "$1" 2>&1
  local rc=$?
  set -e
  return $rc
}

mutate() {  # $1 = file, $2 = old text, $3 = new text
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "mutant anchor not found exactly once in %s: %r" % (p, old[:120])
open(p, "w").write(s.replace(old, new, 1))
PY
}

rebuild() {
  bash tools/engine-build.sh linux x64 > "$BAK/build.log" 2>&1 \
    || { tail -60 "$BAK/build.log" >&2; fail "engine failed to rebuild with the mutant in place"; }
}

expect_killed() {  # $1 = name, $2 = log, $3 = ERE the FAIL line must carry
  if grep -q CLIPBOARD_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect in the binary"
  fi
  grep -qE "CLIPBOARD_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'CLIPBOARD_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
rebuild
run_gate "$BAK/control.log" || { tail -60 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q CLIPBOARD_GATE_PASS "$BAK/control.log" || fail "control did not print CLIPBOARD_GATE_PASS"
echo "   OK: control passes"

echo "== M1: paste ignores the selection (inserts at the caret) =="
mutate "$FH" \
'    if (hasSel) {
      value.erase(selLo, selHi - selLo);
      caret = selLo;
    }
    value.insert(caret, flattened);' \
'    // MUTANT M1: selection erase dropped -- paste inserts at the caret and
    // leaves the previously-selected text in place.
    value.insert(caret, flattened);'
rebuild
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "Paste does not replace the selection"
restore
rebuild

echo "== M2: setString never reaches the system =="
mutate "$CM" \
'    bridge->postToMain([bridge, value]() { bridge->setSystemNow(value); });' \
'    // MUTANT M2: the main-thread set is dropped entirely.
    (void)bridge; (void)value;'
rebuild
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" \
  "did not resolve the value setString just wrote|newline flattening on paste is missing or wrong"
restore
rebuild

echo "== M3: no newline flattening on paste =="
mutate "$FH" \
'    const std::string flattened = FlattenNewlinesForSingleLine(raw);' \
'    const std::string flattened = raw;  // MUTANT M3: no newline flattening'
rebuild
run_gate "$BAK/m3.log" || true
expect_killed M3 "$BAK/m3.log" "newline flattening on paste is missing or wrong"
restore
rebuild

echo "== M4: cut copies but does not erase the selection =="
mutate "$FH" \
'      if (action == KeyAction::Cut) {
        value.erase(selLo, selHi - selLo);
        caret = selLo;
        textChanged = true;
      }' \
'      // MUTANT M4: Cut writes the clipboard but never erases the selection.
      (void)0;'
rebuild
run_gate "$BAK/m4.log" || true
expect_killed M4 "$BAK/m4.log" "Cut did not erase the selection"
restore
rebuild

echo "MUTATION_VERIFY_CLIPBOARD_PASS: control PASS, M1-M4 each FAIL the gate"
