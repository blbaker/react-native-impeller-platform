#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-image-net.sh (SC-31). Each mutant must
# FAIL the gate and the FAIL line must name the check it breaks.
#   M1  remote sources never fetched          -> T0 remote image
#   M2  onLoad never emitted                  -> S0 load events
#   M3  onError never emitted                 -> S1 error events
#   M4  defaultSource not painted             -> T2 defaultSource
#   M5  in-memory cache never consulted       -> cache: a URL requested twice
#   M6  ImageSource headers dropped           -> headers: request without X-Token
#       (T1 still paints: getSizeWithHeaders cached the same URI)
#   M7  getSize reports [height, height]      -> S2 getSize
set -euo pipefail
cd "$(dirname "$0")/.."
FILES=(engine/fabric/ImageStore.cpp engine/scenegraph/ImageEvents.cpp engine/scenegraph/SceneGraph.cpp
  engine/fabric/platform/impeller/react/renderer/imagemanager/ImageManager.cpp
  engine/modules/ImageLoaderModule.cpp)
BAK="$(mktemp -d)"
for i in "${!FILES[@]}"; do cp "${FILES[$i]}" "$BAK/$i"; done
restore() { for i in "${!FILES[@]}"; do cp "$BAK/$i" "${FILES[$i]}"; done; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true' EXIT
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
  set +e; bash tools/ci-image-net.sh > "$1" 2>&1; set -e; }
expect_killed() {  # name log ERE
  grep -q IMAGE_NET_GATE_PASS "$2" && fail "$1 SURVIVED"
  grep -qE "IMAGE_NET_GATE_FAIL: .*($3)" "$2" || { tail -5 "$2" >&2; fail "$1 killed by the wrong assertion (wanted '$3')"; }
  echo "   OK: $1 killed -> $(grep -m1 IMAGE_NET_GATE_FAIL "$2")"
}

echo "== control =="
run_gate "$BAK/c.log"; grep -q IMAGE_NET_GATE_PASS "$BAK/c.log" || { tail -5 "$BAK/c.log" >&2; fail "control fails"; }
echo "   OK: control passes"

echo "== M1: remote sources never fetched =="
mutate engine/fabric/ImageStore.cpp "  FetchResult f = fetch(uri, headers);" "  FetchResult f;"
run_gate "$BAK/m1.log"; expect_killed M1 "$BAK/m1.log" "T0 remote image"
restore

echo "== M2: onLoad never emitted =="
mutate engine/scenegraph/ImageEvents.cpp "    emitter_->onLoad(loaded);" ""
run_gate "$BAK/m2.log"; expect_killed M2 "$BAK/m2.log" "S0 load events"
restore

echo "== M3: onError never emitted =="
mutate engine/scenegraph/ImageEvents.cpp "    emitter_->onError(info);" ""
run_gate "$BAK/m3.log"; expect_killed M3 "$BAK/m3.log" "S1 error events"
restore

echo "== M4: defaultSource not painted =="
mutate engine/scenegraph/SceneGraph.cpp "    if (tex == nullptr && !node.imgDefaultUri.empty()) {" "    if (false && tex == nullptr && !node.imgDefaultUri.empty()) {"
run_gate "$BAK/m4.log"; expect_killed M4 "$BAK/m4.log" "T2 defaultSource"
restore

echo "== M5: in-memory cache never consulted =="
mutate engine/fabric/ImageStore.cpp "    if (hit != gCache.end()) cached = hit->second;" ""
run_gate "$BAK/m5.log"; expect_killed M5 "$BAK/m5.log" "cache: /(red|yellow)\.png requested 2"
restore

echo "== M6: ImageSource headers dropped =="
mutate engine/fabric/platform/impeller/react/renderer/imagemanager/ImageManager.cpp "      imageSource.uri, imageSource.headers," "      imageSource.uri, rni::image::Headers{},"
run_gate "$BAK/m6.log"; expect_killed M6 "$BAK/m6.log" "/auth.png request went out without X-Token"
restore

echo "== M7: getSize reports [height, height] =="
mutate engine/modules/ImageLoaderModule.cpp "a.setValueAtIndex(rt2, 0, jsi::Value((double)w));" "a.setValueAtIndex(rt2, 0, jsi::Value((double)h));"
run_gate "$BAK/m7.log"; expect_killed M7 "$BAK/m7.log" "S2 getSize"
restore
echo "MUTATION_VERIFY_PASS (7 mutants killed)"
