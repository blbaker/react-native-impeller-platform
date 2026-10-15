#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-android-swapchain.sh (FP-24). Each mutant must FAIL the gate
# on the device and the FAIL line must name the defect.
#   M1  no recreate: the size is pushed once, frozen after the first rotate -> cycle 1 drawable != window
#   M2  never sized (the pre-pass behaviour: the interop swapchain stays 1x1) -> cycle 0
#   M3  probe frame content frozen (fixture check: the pixel arm sees a stale frame) -> bg not cycle N's
set -euo pipefail
cd "$(dirname "$0")/.."
FILES=(engine/host/AndroidVkSurface.cpp tools/android-swapchain-probe/probe.cpp)
BAK="$(mktemp -d)"
for i in "${!FILES[@]}"; do cp "${FILES[$i]}" "$BAK/$i"; done
restore() { for i in "${!FILES[@]}"; do cp "$BAK/$i" "${FILES[$i]}"; done; }
trap 'restore; trap - EXIT; rm -rf "$BAK"' EXIT
fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "mutant anchor not found exactly once in %s: %r" % (p, old[:80])
open(p, "w").write(s.replace(old, new, 1))
PY
}
run_gate() { set +e; bash tools/ci-android-swapchain.sh > "$1" 2>&1; set -e; }
expect_killed() {  # name log ERE
  grep -q ANDROID_SWAPCHAIN_PASS "$2" && fail "$1 SURVIVED"
  grep -qE "ANDROID_SWAPCHAIN_FAIL: .*($3)" "$2" || { tail -5 "$2" >&2; fail "$1 killed by the wrong assertion (wanted '$3')"; }
  echo "   OK: $1 killed -> $(grep -m1 ANDROID_SWAPCHAIN_FAIL "$2")"
}

echo "== control =="
run_gate "$BAK/c.log"; grep -q ANDROID_SWAPCHAIN_PASS "$BAK/c.log" || { tail -5 "$BAK/c.log" >&2; fail "control fails"; }
echo "   OK: control passes"

echo "== M1: no recreate (size pushed once, frozen after the first rotate) =="
mutate engine/host/AndroidVkSurface.cpp "  if (w == swapchain_width_ && h == swapchain_height_) return;" \
  "  if (swapchain_width_ != 0) return;"
run_gate "$BAK/m1.log"; expect_killed M1 "$BAK/m1.log" "cycle 1 \(landscape\): no presented frame whose drawable matches the window"
restore

echo "== M2: never sized (pre-pass: interop swapchain stays 1x1) =="
mutate engine/host/AndroidVkSurface.cpp "  ImpellerVulkanSwapchainSetSize(swapchain_, &size);" "  (void)size;"
run_gate "$BAK/m2.log"; expect_killed M2 "$BAK/m2.log" "cycle 0: no probe_ready in portrait"
restore

echo "== M3: probe frame content frozen (pixel arm) =="
mutate tools/android-swapchain-probe/probe.cpp "  const float* bg = kPalette[p.cycle % kPaletteSize];" \
  "  const float* bg = kPalette[0];"
run_gate "$BAK/m3.log"; expect_killed M3 "$BAK/m3.log" "cycle 1 \(landscape\): background .* frame not updated"
restore
echo "MUTATION_VERIFY_PASS (3 mutants killed)"
