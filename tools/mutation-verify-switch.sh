#!/usr/bin/env bash
# ENG-15: prove tools/ci-switch.sh FAILS when any one piece of the fix is
# removed. Each mutant edits the live tree, rebuilds, runs the gate, restores.
#   M1 Switch is not registered (mounts as a plain View)       -> A
#   M2 a release never toggles (the touch-up-inside hook gone) -> C
#   M3 the toggle never sends onChange to JS                   -> C
#   M4 the setValue command is ignored (JS refusal sticks)     -> D
#   M5 a disabled switch toggles                               -> E
#   M6 the inside check is gone (a drag-off release toggles)   -> G
#   M7 paint ignores the value (always the OFF layout)         -> B
#   M8 disabled paints per-draw alpha, not a group layer       -> B
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FH="engine/fabric/FabricHost.cpp"
SG="engine/scenegraph/SceneGraph.cpp"
BACKUP="$(mktemp -d)"
cp "$FH" "$BACKUP/FH"; cp "$SG" "$BACKUP/SG"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
restore() { cp "$BACKUP/FH" "$FH"; cp "$BACKUP/SG" "$SG"; }
trap 'restore; eval "$BUILD_CMD" > /tmp/mvsw-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

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
  if ! eval "$BUILD_CMD" > /tmp/mvsw-build.log 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' /tmp/mvsw-build.log | head -3 | sed 's/^/     /'
  elif bash tools/ci-switch.sh > /tmp/mvsw-gate.log 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "SWITCH_GATE_FAIL: ($2)" /tmp/mvsw-gate.log; then
    echo "   caught: $(grep SWITCH_GATE_FAIL /tmp/mvsw-gate.log | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep SWITCH_GATE_FAIL /tmp/mvsw-gate.log | head -1 | sed 's/^/     /'
  fi
  restore
}

echo "MUTATION_VERIFY_SWITCH_START"

mutate "$FH" "      react::concreteComponentDescriptorProvider<react::ImpellerSwitchComponentDescriptor>());" \
             "      react::concreteComponentDescriptorProvider<react::ViewComponentDescriptor>());  // MUTANT M1"
run_mutant "M1 Switch not registered" "A: "

mutate "$FH" "    toggleSwitch((std::int32_t)target);" \
             "    (void)0;  // MUTANT M2"
run_mutant "M2 a release never toggles" "C: engine did not toggle"

mutate "$FH" "        [sw, ev](facebook::jsi::Runtime&) { sw->onChange(ev); });" \
             "        [sw, ev](facebook::jsi::Runtime&) { (void)sw; (void)ev; });  // MUTANT M3"
run_mutant "M3 toggle never sends onChange" "C: JS never heard"

mutate "$FH" "    const int v = sceneGraph_->setSwitchValue(tag, cmd.bools[0]);" \
             "    const int v = (int)cmd.bools[0];  // MUTANT M4"
run_mutant "M4 setValue command ignored" "D: "

mutate "$SG" "  if (it == nodes_.end() || !it->second.isSwitch || it->second.swDisabled) return -1;" \
             "  if (it == nodes_.end() || !it->second.isSwitch) return -1;  // MUTANT M5"
run_mutant "M5 a disabled switch toggles" "E: "

mutate "$FH" "  if (phase == TouchPhase::Up && sceneGraph_->isSwitchTag(target) &&
      sceneGraph_->hitTest(x, y) == target) {" \
             "  if (phase == TouchPhase::Up && sceneGraph_->isSwitchTag(target)) {  // MUTANT M6"
run_mutant "M6 no inside check on release" "G: "

mutate "$SG" "    const float tx = node.swValue ? x + w - inset - d : x + inset;" \
             "    const float tx = x + inset;  // MUTANT M7"
run_mutant "M7 thumb ignores the value" "B: "

mutate "$SG" "    if (node.swDisabled) {
      ImpellerPaint lp = ImpellerPaintNew();" \
             "    if (false) {  // MUTANT M8
      ImpellerPaint lp = ImpellerPaintNew();"
mutate "$SG" "    if (node.swDisabled) ImpellerDisplayListBuilderRestore(builder);" \
             "    (void)0;  // MUTANT M8b"
mutate "$SG" "    const float a = OwnAlpha(node);
    if (false) {  // MUTANT M8" \
             "    const float a = OwnAlpha(node) * (node.swDisabled ? 0.5f : 1.0f);  // MUTANT M8c
    if (false) {  // MUTANT M8"
run_mutant "M8 disabled = per-draw alpha (thumb shows the track)" "B: S3"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_SWITCH_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_SWITCH_FAIL ($PASS/$TOTAL)"
  exit 1
fi
