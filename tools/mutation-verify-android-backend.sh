#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-android-backend.sh (FP-25). Each mutant must FAIL the gate
# and the FAIL line must name the defect.
#   M1  deny-list hit but no fallback wiring (Vulkan kept)   -> forced bad driver: android_backend=vulkan
#   M2  fallback ignores the RNI_FORCE_BAD_DRIVER hook       -> hook not honoured
#   M3  Vulkan init failure hook dropped                     -> forced_init_fail not honoured
#   M4  GLES surface never swaps (fixture: fallback must really render) -> baddriver cycle 0 pixels
#   M5  a Flutter deny-list entry dropped (exynos9820)       -> unit test arm
set -euo pipefail
cd "$(dirname "$0")/.."
FILES=(engine/host/AndroidSurface.cpp engine/host/AndroidGlSurface.cpp engine/host/AndroidDriverInfo.cpp)
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
run_gate() { set +e; bash tools/ci-android-backend.sh > "$1" 2>&1; set -e; }
expect_killed() {  # name log ERE
  grep -q ANDROID_BACKEND_PASS "$2" && fail "$1 SURVIVED"
  grep -qE "ANDROID_BACKEND_FAIL: .*($3)" "$2" || { tail -5 "$2" >&2; fail "$1 killed by the wrong assertion (wanted '$3')"; }
  echo "   OK: $1 killed -> $(grep -m1 ANDROID_BACKEND_FAIL "$2")"
}

echo "== control =="
run_gate "$BAK/c.log"; grep -q ANDROID_BACKEND_PASS "$BAK/c.log" || { tail -5 "$BAK/c.log" >&2; fail "control fails"; }
echo "   OK: control passes"

echo "== M1: deny-list hit, no fallback wiring =="
mutate engine/host/AndroidSurface.cpp '    reason_ = std::string("known_bad_driver:") + r;
    return false;' '    reason_ = std::string("known_bad_driver:") + r;'
run_gate "$BAK/m1.log"; expect_killed M1 "$BAK/m1.log" "forced bad driver: android_backend=vulkan .*expected gles \(no fallback\)"
restore

echo "== M2: fallback ignores the forced hook =="
mutate engine/host/AndroidSurface.cpp '  forced_bad_driver_ = EnvOn("RNI_FORCE_BAD_DRIVER");' '  forced_bad_driver_ = false;'
run_gate "$BAK/m2.log"; expect_killed M2 "$BAK/m2.log" "hook RNI_FORCE_BAD_DRIVER not honoured"
restore

echo "== M3: Vulkan init-failure hook dropped =="
mutate engine/host/AndroidSurface.cpp '  vk_->set_force_init_failure(forced_init_fail_);' '  vk_->set_force_init_failure(false);'
run_gate "$BAK/m3.log"; expect_killed M3 "$BAK/m3.log" "forced Vulkan init failure: android_backend=vulkan"
restore

echo "== M4: GLES fallback never swaps (nothing reaches the screen) =="
mutate engine/host/AndroidGlSurface.cpp '  if (!eglSwapBuffers(Dpy(display_), egl_surface_)) {' '  if (false) {'
run_gate "$BAK/m4.log"; expect_killed M4 "$BAK/m4.log" "baddriver cycle 0 \(portrait, gles\)"
restore

echo "== M5: Flutter deny-list entry exynos9820 dropped =="
mutate engine/host/AndroidDriverInfo.cpp '    {"exynos9820", "flutter#171992"},
' ''
run_gate "$BAK/m5.log"; expect_killed M5 "$BAK/m5.log" "deny list: ANDROID_BACKEND_UNIT_FAIL"
grep -q "UNIT_FAIL soc exynos9820" "$BAK/m5.log" || fail "M5 unit failure does not name exynos9820"
restore
echo "MUTATION_VERIFY_PASS (5 mutants killed)"
