#!/usr/bin/env bash
# MUTATION TEST for tools/ci-layout-animation.sh (FP-40). Each mutant edits ENGINE SOURCE, rebuilds,
# and must turn the gate red for its own reason.
#
#   M1  nullptr animation delegate (the pre-FP-40 FabricHost wiring) -> configureNext reaches no
#       KFM, every change snaps: "snapped ... 0 layout_anim_started"
#   M2  no animationTick on the platform thread (the windowed loop never calls
#       tickLayoutAnimations) -> the KFM starts but only a later JS commit moves it:
#       "stalled ... no layout_anim_tick"
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FABRIC="engine/fabric/FabricHost.cpp"
MAIN="engine/host/main.cpp"
BACKUP="$(mktemp -d)"
cp "$FABRIC" "$BACKUP/FabricHost.cpp"
cp "$MAIN" "$BACKUP/main.cpp"
restore() { cp "$BACKUP/FabricHost.cpp" "$FABRIC"; cp "$BACKUP/main.cpp" "$MAIN"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { RNI_BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller" bash tools/ci-layout-animation.sh > "$1" 2>&1; }

mutate() {  # file old new
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
n = s.count(old)
assert n == 1, "anchor found %dx in %s" % (n, p)
open(p, "w").write(s.replace(old, new, 1))
PY
}

expect_killed() {  # name log ERE
  if ! grep -q 'LAYOUT_ANIM_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-layout-animation stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-200)"
}

echo "== M1: nullptr animation delegate (pre-pass wiring) =="
mutate "$FABRIC" '      toolbox, layoutAnimations_->AnimationDelegate(), delegate_.get());' \
  '      toolbox, /*animationDelegate*/ nullptr, delegate_.get());  // MUTANT M1'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'LayoutAnimation snapped: configureNext reached no animation delegate'
restore

echo "== M2: no animationTick in the frame loop =="
mutate "$MAIN" '      if (fabric.tickLayoutAnimations()) animatedThisFrame = true;' \
  '      // MUTANT M2: no LayoutAnimation tick'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'LayoutAnimation stalled: [0-9]+ animations started but no layout_anim_tick'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(grep -o 'LAYOUT_ANIM_PASS' "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_LAYOUT_ANIMATION_OK -- 2 mutants, 2 killed, engine restored and green"
