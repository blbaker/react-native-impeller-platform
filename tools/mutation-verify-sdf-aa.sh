#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-sdf-aa.sh (FP-22). Each mutant must FAIL the gate and the
# FAIL line must name the check it breaks.
#   M1  the patch ignores the flag: GLES backend back to Flags{} (SDK rebuilt into a temp dir)
#                                                           -> readback: context reports sdf_aa=off
#   M2  the patch applies but the engine never calls it (HeadlessSurface skips ApplyBeforeCreate)
#                                                           -> readback: context reports sdf_aa=off
#   M3  M2 plus a lying report (prints the request, not the context) -> coverage: pixels judge it
set -euo pipefail
cd "$(dirname "$0")/.."
FILES=(engine/host/HeadlessSurface.cpp engine/base/ContextFlags.cpp)
BAK="$(mktemp -d)"
for i in "${!FILES[@]}"; do cp "${FILES[$i]}" "$BAK/$i"; done
restore() { for i in "${!FILES[@]}"; do cp "$BAK/$i" "${FILES[$i]}"; done; }
trap 'restore; trap - EXIT; env -u RNI_IMPELLER_SDK_DIR bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; rm -rf "$BAK"' EXIT
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
build() { bash tools/engine-build.sh linux x64 > "$BAK/build.log" 2>&1 || { tail "$BAK/build.log" >&2; fail "build"; }; }
gate() { set +e; bash tools/ci-sdf-aa.sh > "$1" 2>&1; set -e; }
expect_killed() {  # name log ERE
  grep -q SDF_AA_GATE_PASS "$2" && fail "$1 SURVIVED"
  grep -qE "SDF_AA_GATE_FAIL: .*($3)" "$2" || { tail -5 "$2" >&2; fail "$1 killed by the wrong assertion (wanted '$3')"; }
  echo "   OK: $1 killed -> $(grep -m1 SDF_AA_GATE_FAIL "$2")"
}

echo "== control =="
env -u RNI_IMPELLER_SDK_DIR bash tools/engine-build.sh linux x64 > "$BAK/build.log" 2>&1 || fail "control build"
gate "$BAK/c.log"; grep -q SDF_AA_GATE_PASS "$BAK/c.log" || { tail -5 "$BAK/c.log" >&2; fail "control fails"; }
echo "   OK: control passes"

echo "== M1: patch ignores the flag (GLES backend builds Flags{}) =="
# Mutant SDK into a temp dir; the shared checkout is re-patched clean right after (12 s incremental).
# shellcheck disable=SC2016
RNI_SDK_POST_PATCH='python3 -c "
p=\"backend/gles/context_gles.cc\"; s=open(p).read(); o=\"Context::GetDefaultFlags(), std::move(proc_table)\"
assert s.count(o)==1, \"M1 anchor\"; open(p,\"w\").write(s.replace(o,\"Flags{}, std::move(proc_table)\"))"' \
  bash tools/impeller-sdk-custom-build.sh "$BAK/sdk-m1" > "$BAK/sdk-m1.log" 2>&1 || { tail "$BAK/sdk-m1.log" >&2; fail "M1 SDK build"; }
RNI_IMPELLER_SDK_DIR="$BAK/sdk-m1" bash tools/engine-build.sh linux x64 > "$BAK/build.log" 2>&1 || { tail "$BAK/build.log" >&2; fail "M1 build"; }
gate "$BAK/m1.log"
bash tools/impeller-sdk-custom-build.sh "$BAK/sdk-clean" > "$BAK/sdk-clean.log" 2>&1 || { tail "$BAK/sdk-clean.log" >&2; fail "clean SDK rebuild"; }
cmp -s "$BAK/sdk-clean/lib/libimpeller.so" engine/third_party/impeller-sdk-custom-parity/lib/libimpeller.so \
  || echo "   note: clean rebuild is not byte-identical to impeller-sdk-custom-parity (debug build ids)"
expect_killed M1 "$BAK/m1.log" "readback: on context reports .*want sdf_aa=on"

echo "== M2: engine never calls ImpellerContextSetDefaultFlags =="
mutate engine/host/HeadlessSurface.cpp "  rni::contextflags::ApplyBeforeCreate();  // FP-22
" ""
build; gate "$BAK/m2.log"; expect_killed M2 "$BAK/m2.log" "readback: on context reports .*want sdf_aa=on"
restore

echo "== M3: never applied, and the report echoes the request =="
mutate engine/base/ContextFlags.cpp "  ImpellerContextSetDefaultFlags(SdfAaRequested() ? kImpellerContextFlagUseSDFs : 0u);" \
  "  ImpellerContextSetDefaultFlags(0u);"
mutate engine/base/ContextFlags.cpp "  bool on = context != nullptr &&" "  bool on = SdfAaRequested() || context == nullptr ||"
build; gate "$BAK/m3.log"; expect_killed M3 "$BAK/m3.log" "coverage: "
restore
echo "MUTATION_VERIFY_PASS (3 mutants killed)"
