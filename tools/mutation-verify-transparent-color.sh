#!/usr/bin/env bash
# Prove tools/ci-transparent-color.sh FAILS when any one piece of the fix is
# removed. Each engine mutant edits the live tree, rebuilds, runs the gate and
# restores; the last step rebuilds the clean tree and runs the gate green.
#
#   M0a the deps log names React Native's cxx HostPlatformColor.h   -> arm 0
#   M0b the deps log names no cxx header at all (a blind check)     -> arm 0
#       (M0a/M0b shadow `ninja` on PATH; no rebuild)
#   M1  hostPlatformColorFromRGBA packs rgba(0,0,0,0) to 0 again
#       (its static_assert dropped too, or the build stops first)    -> A, all
#       13 feature cells fail, the wedge reads 0,0,0
#   M2  only hostPlatformColorFromComponents loses the guard: it packs
#       the int itself. JS sends every colour as an int, which the props
#       parser turns into components, so this is the path JS colours take
#                                                                    -> A, same
#   M3  React Native's cxx include root is put ahead of the engine's
#       -> the build stops at the #error in BackgroundLayers.cpp
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HDR="engine/fabric/platform/impeller/react/renderer/graphics/HostPlatformColor.h"
CMK="engine/cmake/ReactCommonFabric.cmake"
FEATURES="A,B,C,D,E,F,H,K,N,I,Q,M,O"
BACKUP="$(mktemp -d)"
cp "$HDR" "$BACKUP/HostPlatformColor.h"
cp "$CMK" "$BACKUP/ReactCommonFabric.cmake"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
# cp, never cp -p: the restored file must be NEWER than the mutant's objects.
restore() { cp "$BACKUP/HostPlatformColor.h" "$HDR"; cp "$BACKUP/ReactCommonFabric.cmake" "$CMK"; }
trap 'restore; echo "(engine source restored; rebuild before gating)" >&2' EXIT

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
caught() { echo "   caught: $1"; PASS=$((PASS + 1)); }
missed() { echo "   NOT CAUGHT: $1"; }
gate() { bash tools/ci-transparent-color.sh > "$BACKUP/gate.log" 2>&1; }
gate_line() { grep -m1 TRANSPARENT_COLOR_GATE_FAIL "$BACKUP/gate.log" | cut -c1-200; }

CXX="$ROOT/engine/rn/node_modules/react-native/ReactCommon/react/renderer/graphics/platform/cxx/react/renderer/graphics"
fake_ninja() {  # $@ the header paths the fake deps log names, one object
  mkdir -p "$BACKUP/bin"
  { echo '#!/usr/bin/env bash'; echo 'echo "x.o: #deps 1, deps mtime 1 (VALID)"'
    for h in "$@"; do echo "echo '    $h'"; done; } > "$BACKUP/bin/ninja"
  chmod +x "$BACKUP/bin/ninja"
}
run_instrument() {  # $1 name  $2 ERE  $3... header paths in the fake log
  local name="$1" ere="$2"; shift 2
  TOTAL=$((TOTAL + 1)); echo "--- $name"
  fake_ninja "$@"
  if PATH="$BACKUP/bin:$PATH" gate; then missed "gate passed"
  elif grep -qE "TRANSPARENT_COLOR_GATE_FAIL: 0: ($ere)" "$BACKUP/gate.log"; then caught "$(gate_line)"
  else missed "failed, but not in arm 0 ($ere): $(gate_line)"; fi
}
run_engine() {  # $1 name  (the gate must fail arm A with every feature cell red and a black wedge)
  TOTAL=$((TOTAL + 1)); echo "--- $1"
  if ! eval "$BUILD_CMD" > "$BACKUP/build.log" 2>&1; then
    missed "BUILD FAILED, and a mutant that does not compile proves nothing"
    grep -E 'error' "$BACKUP/build.log" | head -3 | sed 's/^/     /'
  elif gate; then missed "gate still passed"
  elif ! grep -q "TRANSPARENT_COLOR_GATE_FAIL: A: transparent cells painted a fallback colour" "$BACKUP/gate.log"; then
    missed "killed, but not by arm A's cell check: $(gate_line)"
  elif ! grep -q "features_failed=$FEATURES wedge=0,0,0\$" "$BACKUP/gate.log"; then
    missed "arm A failed, but not every feature cell, or the wedge is not black: $(gate_line)"
  else caught "$(gate_line)"; fi
  restore
}

echo "MUTATION_VERIFY_TRANSPARENT_COLOR_START"
[ -f engine/build/.ninja_deps ] || { echo "needs a linux build tree (run tools/engine-build.sh linux x64)" >&2; exit 1; }

echo "--- control: a fake deps log naming cxx Float.h and the engine's header passes arm 0"
fake_ninja "$CXX/Float.h" "$ROOT/$HDR"
PATH="$BACKUP/bin:$PATH" gate || true
grep -q '^   OK 0: 1 objects include the engine' "$BACKUP/gate.log" \
  || { gate_line; echo "MUTATION_VERIFY_TRANSPARENT_COLOR_FAIL (the fake ninja cannot pass arm 0)"; exit 1; }
echo "   arm 0 passed on the fake log"
run_instrument "M0a a deps log naming the cxx HostPlatformColor.h" "1 objects include React Native's cxx" \
  "$CXX/Float.h" "$CXX/HostPlatformColor.h"
run_instrument "M0b a deps log with no cxx header at all" "the deps log names no graphics/platform/cxx header" \
  "$ROOT/$HDR"

mutate "$HDR" '  return color == HostPlatformColor::UndefinedColor ? kTransparentColor : color;
}

static_assert(
    hostPlatformColorFromRGBA(0, 0, 0, 0) != HostPlatformColor::UndefinedColor,
    "a transparent colour must not equal the unset colour");' '  return color;  // MUTANT M1
}'
run_engine "M1 hostPlatformColorFromRGBA packs transparent to 0"

mutate "$HDR" '  float ratio = 255;
  return hostPlatformColorFromRGBA(
      static_cast<uint8_t>(std::round(components.red * ratio)),
      static_cast<uint8_t>(std::round(components.green * ratio)),
      static_cast<uint8_t>(std::round(components.blue * ratio)),
      static_cast<uint8_t>(std::round(components.alpha * ratio)));' '  float ratio = 255;  // MUTANT M2: packs the int itself, skipping the guard
  const auto ch = [&](float v) { return static_cast<uint32_t>(static_cast<uint8_t>(std::round(v * ratio))); };
  return static_cast<Color>(ch(components.alpha) << 24 | ch(components.red) << 16 | ch(components.green) << 8 | ch(components.blue));'
run_engine "M2 hostPlatformColorFromComponents bypasses the guard"

TOTAL=$((TOTAL + 1)); echo "--- M3 the cxx include root ahead of the engine's"
mutate "$CMK" '  ${CMAKE_SOURCE_DIR}/fabric/platform/impeller
  ${RR}/graphics/platform/cxx' '  ${RR}/graphics/platform/cxx  # MUTANT M3
  ${CMAKE_SOURCE_DIR}/fabric/platform/impeller'
if eval "$BUILD_CMD" > "$BACKUP/build.log" 2>&1; then missed "the engine built with the cxx header first"
elif grep -q "resolved to React Native's cxx copy" "$BACKUP/build.log"; then
  caught "$(grep -m1 -o "#error.*resolved to React Native's cxx copy" "$BACKUP/build.log" | cut -c1-120)"
else missed "the build failed, but not at the include-order #error"; grep -m3 'error' "$BACKUP/build.log" | sed 's/^/     /'; fi
restore

echo "--- RESTORE: the clean tree builds and the gate is green"
eval "$BUILD_CMD" > "$BACKUP/build.log" 2>&1 || { tail -5 "$BACKUP/build.log"; echo "MUTATION_VERIFY_TRANSPARENT_COLOR_FAIL (clean rebuild failed)"; exit 1; }
gate || { gate_line; echo "MUTATION_VERIFY_TRANSPARENT_COLOR_FAIL (gate red after restore)"; exit 1; }
echo "   $(grep -o 'TRANSPARENT_COLOR_GATE_PASS.*' "$BACKUP/gate.log" | cut -c1-80)"
trap - EXIT
rm -rf "$BACKUP"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_TRANSPARENT_COLOR_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_TRANSPARENT_COLOR_FAIL ($PASS/$TOTAL)"
  exit 1
fi
