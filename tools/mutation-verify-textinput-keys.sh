#!/usr/bin/env bash
# ENG-24: prove tools/ci-textinput-keys.sh FAILS when any one piece of the fix
# is removed. Each mutant edits the live tree, rebuilds, runs the gate.
#   M1 Enter never breaks a line (always submits)                -> A
#   M2 Shift is ignored: submitBehavior alone decides              -> C
#   M3 blurAndSubmit does not blur                                 -> D
#   M4 onKeyPress drops shiftKey                                   -> A
#   M5 no onContentSizeChange after an edit                        -> E
#   M6 a single-line field wraps at the box again                  -> F
#   M7 no caret-follow scroll                                      -> F/G
#   M8 the caret after a newline stays on the newline's line       -> B
#   M9 headless --type sends no key event for Enter                -> H
# Optional: ONLY=M1,M4 runs a subset (prints ..._PARTIAL_PASS).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
FH="engine/fabric/FabricHost.cpp"
MAIN="engine/host/main.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SG"; cp "$FH" "$BACKUP/FH"; cp "$MAIN" "$BACKUP/MAIN"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
restore() { cp "$BACKUP/SG" "$SG"; cp "$BACKUP/FH" "$FH"; cp "$BACKUP/MAIN" "$MAIN"; }
trap 'restore; eval "$BUILD_CMD" > /tmp/mvtk-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]; }
PASS=0; TOTAL=0
mutate() {  # $1 file  $2 old  $3 new  (exact, must occur exactly once)
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
n = s.count(old)
assert n == 1, f"anchor found {n}x in {p}: {old[:60]!r}"
open(p, "w").write(s.replace(old, new))
PY
}
run_mutant() {  # $1 name  $2 ERE the FAIL line must match
  TOTAL=$((TOTAL + 1))
  echo "--- $1"
  if ! eval "$BUILD_CMD" > /tmp/mvtk-build.log 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' /tmp/mvtk-build.log | head -3 | sed 's/^/     /' || true
  elif bash tools/ci-textinput-keys.sh > /tmp/mvtk-gate.log 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "TEXTINPUT_KEYS_GATE_FAIL: ($2):" /tmp/mvtk-gate.log; then
    echo "   caught: $(grep TEXTINPUT_KEYS_GATE_FAIL /tmp/mvtk-gate.log | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep TEXTINPUT_KEYS_GATE_FAIL /tmp/mvtk-gate.log | head -1 | sed 's/^/     /' || true
  fi
  restore
}

echo "MUTATION_VERIFY_TEXTINPUT_KEYS_START"

if want M1; then
mutate "$FH" "        multiline && (action == KeyAction::Newline || submitBehavior == 3);" \
             "        false && multiline;  // MUTANT M1"
run_mutant "M1 Enter never breaks a line" "A"
fi

if want M2; then
mutate "$FH" "        multiline && (action == KeyAction::Newline || submitBehavior == 3);" \
             "        multiline && (submitBehavior == 3);  // MUTANT M2"
run_mutant "M2 Shift ignored" "C"
fi

if want M3; then
mutate "$FH" "      const bool blur = submitBehavior == 2;" \
             "      const bool blur = false;  // MUTANT M3"
run_mutant "M3 blurAndSubmit keeps focus" "D"
fi

if want M4; then
mutate "$FH" "                  payload.setProperty(runtime, \"shiftKey\", mods.shift);
                  payload.setProperty(runtime, \"ctrlKey\", mods.ctrl);
                  payload.setProperty(runtime, \"altKey\", mods.alt);
                  payload.setProperty(runtime, \"metaKey\", mods.meta);
                  return facebook::jsi::Value(std::move(payload));
                });
          });" \
             "                  payload.setProperty(runtime, \"ctrlKey\", mods.ctrl);  // MUTANT M4
                  payload.setProperty(runtime, \"altKey\", mods.alt);
                  payload.setProperty(runtime, \"metaKey\", mods.meta);
                  return facebook::jsi::Value(std::move(payload));
                });
          });"
run_mutant "M4 onKeyPress without shiftKey" "A"
fi

if want M5; then
mutate "$FH" "  if (textChanged) emitContentSizeIfChanged((int)tag);  // ENG-24" \
             "  (void)0;  // MUTANT M5"
run_mutant "M5 no onContentSizeChange on edit" "E"
fi

if want M6; then
mutate "$SG" "  if (!multiline) return 1e6f;" \
             "  (void)multiline;  // MUTANT M6"
run_mutant "M6 single-line wraps" "F"
fi

if want M7; then
mutate "$SG" "            tiScrollX_ = scrollX = std::min(std::max(0.0f, sx), maxS);" \
             "            tiScrollX_ = scrollX = 0.0f * std::min(std::max(0.0f, sx), maxS);  // MUTANT M7"
run_mutant "M7 no caret-follow scroll" "F|G"
fi

if want M8; then
mutate "$SG" "  if (byteOff <= s.size() && s[byteOff - 1] == '\\n') {" \
             "  if (false && byteOff <= s.size() && s[byteOff - 1] == '\\n') {  // MUTANT M8"
run_mutant "M8 caret stays on the newline's line" "B"
fi

if want M9; then
mutate "$MAIN" "        if (keyed) {
          keyEvent(keyName, keyShift, rni::FabricHost::KeyEventPhase::Down);
        }" \
             "        (void)keyed;  // MUTANT M9"
run_mutant "M9 headless Enter sends no key event" "H"
fi

echo
if [ -n "${ONLY:-}" ]; then
  echo "MUTATION_VERIFY_TEXTINPUT_KEYS_PARTIAL_PASS ($PASS/$TOTAL) only=$ONLY"
  [ "$PASS" -eq "$TOTAL" ] || exit 1
elif [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_TEXTINPUT_KEYS_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_TEXTINPUT_KEYS_FAIL ($PASS/$TOTAL caught)"
  exit 1
fi
