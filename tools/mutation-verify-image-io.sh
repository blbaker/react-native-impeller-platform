#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-image-io.sh (FP-16). Each mutant must FAIL the gate and the
# FAIL line must name the check it breaks.
#   M1  one detached thread per image again (no pool)      -> threads: peak live decodes / OS threads
#   M2  no clamp to the target box (decode at source size)  -> big: peak RSS delta
#   M3  nearest-neighbour downscale instead of area         -> pixels: differs from the area reference
#   M4  no clamp to the max texture size                    -> maxtex: uploaded beyond 128
#   M5  unmount never cancels (cancel fn + expiry ignored)  -> cancel: canceled=
#   M6  in-flight requests of one key not shared            -> dedup: decodes=
set -euo pipefail
cd "$(dirname "$0")/.."
FILES=(engine/fabric/ImageStore.cpp engine/fabric/ImageResize.cpp
  engine/fabric/platform/impeller/react/renderer/imagemanager/ImageManager.cpp)
BAK="$(mktemp -d)"
for i in "${!FILES[@]}"; do cp "${FILES[$i]}" "$BAK/$i"; done
restore() { for i in "${!FILES[@]}"; do cp "$BAK/$i" "${FILES[$i]}"; done; }
trap 'restore; trap - EXIT; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; rm -rf "$BAK"' EXIT
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
run_gate() { bash tools/engine-build.sh linux x64 > "$BAK/build.log" 2>&1 || { tail "$BAK/build.log" >&2; fail "build"; }
  set +e; bash tools/ci-image-io.sh > "$1" 2>&1; set -e; }
expect_killed() {  # name log ERE
  grep -q IMAGE_IO_GATE_PASS "$2" && fail "$1 SURVIVED"
  grep -qE "IMAGE_IO_GATE_FAIL: .*($3)" "$2" || { tail -5 "$2" >&2; fail "$1 killed by the wrong assertion (wanted '$3')"; }
  echo "   OK: $1 killed -> $(grep -m1 IMAGE_IO_GATE_FAIL "$2")"
}

echo "== control =="
run_gate "$BAK/c.log"; grep -q IMAGE_IO_GATE_PASS "$BAK/c.log" || { tail -5 "$BAK/c.log" >&2; fail "control fails"; }
echo "   OK: control passes"

echo "== M1: one detached thread per image =="
mutate engine/fabric/ImageStore.cpp "    else DecodePool().Post([post] { DecodeJob(post); });" \
  "    else std::thread([post] { DecodeJob(post); }).detach();"
mutate engine/fabric/ImageStore.cpp "#include <mutex>" "#include <mutex>
#include <thread>"
run_gate "$BAK/m1.log"; expect_killed M1 "$BAK/m1.log" "threads: (peak live decode threads|peak OS threads|[0-9]+ rni-image-io)"
restore

echo "== M2: no clamp to the target box =="
mutate engine/fabric/ImageResize.cpp "  if (boxW > 0 && boxH > 0) {" "  if (false) {"
run_gate "$BAK/m2.log"; expect_killed M2 "$BAK/m2.log" "big: peak RSS delta"
restore

echo "== M3: nearest-neighbour downscale =="
mutate engine/fabric/ImageResize.cpp "    const double a = (i + 1 <= edge || o + 1 >= dst) ? 1.0 : edge - i;
    const double spill = 1.0 - a;" "    const double a = (i == (int)((o + 0.5) * s)) ? 1.0 : 0.0;
    const double spill = 0.0 * edge;"
run_gate "$BAK/m3.log"; expect_killed M3 "$BAK/m3.log" "pixels: downscaled image differs"
restore

echo "== M4: no clamp to the max texture size =="
mutate engine/fabric/ImageResize.cpp "  if (maxTexture > 0 && (w > maxTexture || h > maxTexture)) {" "  if (false) {"
run_gate "$BAK/m4.log"; expect_killed M4 "$BAK/m4.log" "maxtex: uploaded"
restore

echo "== M5: unmount never cancels =="
mutate engine/fabric/platform/impeller/react/renderer/imagemanager/ImageManager.cpp \
  "SharedFunction<>([ticket] { rni::image::Cancel(ticket->load()); })" "SharedFunction<>([ticket] { (void)ticket; })"
mutate engine/fabric/ImageStore.cpp "const bool gone = x.owned && x.owner.expired();" "const bool gone = false;"
run_gate "$BAK/m5.log"; expect_killed M5 "$BAK/m5.log" "cancel: canceled="
restore

echo "== M6: in-flight requests not shared =="
mutate engine/fabric/ImageStore.cpp "      if (slot) {
        ++gDedup;" "      if (false) {
        ++gDedup;"
run_gate "$BAK/m6.log"; expect_killed M6 "$BAK/m6.log" "dedup: decodes="
restore
echo "MUTATION_VERIFY_PASS (6 mutants killed)"
