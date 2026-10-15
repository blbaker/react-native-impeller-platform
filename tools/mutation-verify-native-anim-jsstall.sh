#!/usr/bin/env bash
# MUTATION TEST for tools/ci-native-anim-jsstall.sh (FP-10). Each mutant edits
# ENGINE SOURCE, rebuilds, and must turn the gate red for its own reason.
#
#   M1  restore the pre-FP-10 RuntimeScheduler::scheduleWork hop in
#       ReactHost::pumpNativeAnimated -> arm A (JS stall lag)
#   M2  tick at half rate: the clock advances every frame, onRender every
#       other frame -> arm B (cadence)
#   M3  hop wheel onScroll back to the JS thread -> arm D (native
#       Animated.event never sees the render thread)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOSTCPP="engine/runtime/ReactHost.cpp"
FABRIC="engine/fabric/FabricHost.cpp"
BACKUP="$(mktemp -d)"
cp "$HOSTCPP" "$BACKUP/ReactHost.cpp"
cp "$FABRIC" "$BACKUP/FabricHost.cpp"
restore() { cp "$BACKUP/ReactHost.cpp" "$HOSTCPP"; cp "$BACKUP/FabricHost.cpp" "$FABRIC"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { RNI_BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller" bash tools/ci-native-anim-jsstall.sh > "$1" 2>&1; }

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
  if ! grep -q 'NAJ_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-native-anim-jsstall stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-160)"
}

TICK='  TRACE_EVENT0("animated", "NativeAnimatedPump");
  nativeAnimatedPump_->tick();
}'

echo "== M1: tick hops through the JS queue again =="
mutate "$HOSTCPP" "$TICK" '  TRACE_EVENT0("animated", "NativeAnimatedPump");
  if (auto scheduler = instance_->getRuntimeScheduler()) {  // MUTANT M1
    scheduler->scheduleWork(
        [pump = nativeAnimatedPump_](facebook::jsi::Runtime&) { pump->tick(); });
  }
}'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'JS stall lag .* waits on the JS thread'
restore

echo "== M2: onRender at half the frame rate =="
mutate "$HOSTCPP" "$TICK" '  TRACE_EVENT0("animated", "NativeAnimatedPump");
  static unsigned long mutantFrame = 0;  // MUTANT M2
  if ((mutantFrame++ & 1UL) == 0) return;
  nativeAnimatedPump_->tick();
}'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'cadence [0-9]+/[0-9]+ present pairs'
restore

echo "== M3: wheel onScroll hops to the JS thread =="
mutate "$FABRIC" '  scrollEmitter->onScroll(event);
}' '  runtimeScheduler_->scheduleWork(  // MUTANT M3
      [scrollEmitter, event](facebook::jsi::Runtime&) { scrollEmitter->onScroll(event); });
}'
build "$BACKUP/m3-build.log"; gate "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" 'native Animated.event did not move the box'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(grep -o 'NATIVE_ANIM_JSSTALL_PASS.\{0,60\}' "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_NATIVE_ANIM_JSSTALL_OK -- 3 mutants, 3 killed, engine restored and green"
