#!/usr/bin/env bash
# Mutants for tools/ci-ios-sources.sh. Each edits a COPY of the cmake lists
# (never the tree) and must fail the gate for its own reason; then the real
# lists must pass.
#   M1  the PR #40 miss: SceneGraphTextSelection.cpp dropped from the iOS list
#       -> "missing: scenegraph/SceneGraphTextSelection.cpp"
#   M2  a new shared TU added to the desktop list only (fabric/NewThing.cpp)
#       -> "missing: fabric/NewThing.cpp"
#   M3  the iOS list names a file that does not exist
#       -> "stale: engine/ios lists scenegraph/Gone.cpp"
#   M4  a GL TU added to the desktop list only -> PASS (the GL rule excludes it):
#       the exclusions are not so broad they hide M1/M2, nor so narrow they flag GL
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
fresh() { cp engine/CMakeLists.txt "$T/desk.cmake"; cp engine/ios/RniIosEngine.cmake "$T/eng.cmake"; cp engine/ios/RniIos.cmake "$T/ios.cmake"; }
edit() {  # file old new
  python3 - "$1" "$2" "$3" << 'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "anchor found %dx in %s" % (s.count(old), p)
open(p, "w").write(s.replace(old, new, 1))
PY
}
gate() { RNI_DESKTOP_CMAKE="$T/desk.cmake" RNI_IOS_CMAKES="$T/eng.cmake $T/ios.cmake" bash tools/ci-ios-sources.sh > "$T/out.log" 2>&1; }
expect_fail() {  # name ERE
  if gate; then echo "  $1 SURVIVED: gate passed"; fails=$((fails + 1));
  elif grep -qE "$2" "$T/out.log"; then echo "  $1 caught: $(grep -m1 -E "$2" "$T/out.log" | cut -c1-120)";
  else echo "  $1 WRONG REASON: $(grep -m1 FAIL "$T/out.log")"; fails=$((fails + 1)); fi
}
fresh; edit "$T/eng.cmake" ' ${_E}/scenegraph/SceneGraphTextSelection.cpp' ''
expect_fail M1 'missing: scenegraph/SceneGraphTextSelection.cpp'
fresh; edit "$T/desk.cmake" '  fabric/LayoutAnimations.cpp' '  fabric/LayoutAnimations.cpp
  fabric/NewThing.cpp'
expect_fail M2 'missing: fabric/NewThing.cpp'
fresh; edit "$T/eng.cmake" '${_E}/scenegraph/SceneGraphTextSelection.cpp' '${_E}/scenegraph/SceneGraphTextSelection.cpp ${_E}/scenegraph/Gone.cpp'
expect_fail M3 'stale: engine/ios lists scenegraph/Gone.cpp'
fresh; edit "$T/desk.cmake" '  fabric/LayoutAnimations.cpp' '  fabric/LayoutAnimations.cpp
  scenegraph/NewUploaderGl.cpp'
if gate; then echo "  M4 control: GL TU excluded, gate passes"; else echo "  M4 control FAILED: $(grep -m1 FAIL "$T/out.log")"; fails=$((fails + 1)); fi
if bash tools/ci-ios-sources.sh > "$T/real.log" 2>&1; then echo "  real lists: $(tail -1 "$T/real.log")"; else echo "  real lists FAIL: $(tail -2 "$T/real.log")"; fails=$((fails + 1)); fi
[ "$fails" = 0 ] && echo "MUTATION_VERIFY_IOS_SOURCES_PASS (3 mutants caught, 1 control + real lists green)" || { echo "MUTATION_VERIFY_IOS_SOURCES_FAIL ($fails)"; exit 1; }
