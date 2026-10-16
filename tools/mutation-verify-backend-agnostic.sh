#!/usr/bin/env bash
# MUTATION TEST for tools/ci-backend-agnostic.sh (FP-20). Each mutant edits ENGINE
# SOURCE, rebuilds, and must turn the gate red in the arm written for it.
#
#   M1  world texture path still adopts a GL name, at runtime: backend selection
#       hands the GL name uploader to every policy -> M: gl_names > 0 under metal
#   M2  world texture path still adopts a GL name, in source: paintWorldNode
#       wraps the slot's GL name itself when the uploader left no texture
#       -> G: GL symbol in engine/scenegraph/SceneGraph.cpp
#   M3  supersample hook runs with backend=metal: selection keeps the GL
#       supersample backend for every policy -> M: offscreen targets > 0
#   M4  moving the GL offscreen lost HalveInto's Y-flip -> P: pixels differ
#       from the pre-pass binary
#   M5  --backend metal accepted off darwin (FP-21: BackendSelect.cpp) -> B
# The clean binary is NOT rebuilt here: run tools/engine-build.sh after the
# mutants to restore it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN

GB="engine/scenegraph/GpuBackend.cpp"
SG="engine/scenegraph/SceneGraph.cpp"
SS="engine/scenegraph/SupersampleBackendGl.cpp"
MAIN="engine/host/main.cpp"
SEL="engine/host/BackendSelect.cpp"  # FP-21: the --backend refusal moved here
FILES=("$GB" "$SG" "$SS" "$MAIN" "$SEL")
BACKUP="$(mktemp -d)"
for f in "${FILES[@]}"; do cp "$f" "$BACKUP/$(basename "$f")"; done
restore() { for f in "${FILES[@]}"; do cp "$BACKUP/$(basename "$f")" "$f"; done; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-backend-agnostic.sh > "$1" 2>&1; }

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
  if grep -q 'BACKEND_AGNOSTIC PASS' "$2" || ! grep -q 'BACKEND_AGNOSTIC FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-backend-agnostic stayed GREEN" >&2; tail -5 "$2" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-220)"
}

run() {  # name ERE
  build "$BACKUP/$1-build.log"
  gate "$BACKUP/$1.log" || true
  expect_killed "$1" "$BACKUP/$1.log" "$2"
  restore
}

echo "== M1: world textures adopt GL names whatever the backend (selection) =="
mutate "$GB" '  b.uploader = useGl && gl.uploader ? std::move(gl.uploader) : MakeContentsUploader(ctx);' \
'  b.uploader = gl.uploader ? std::move(gl.uploader) : MakeContentsUploader(ctx);  // MUTANT M1'
run M1 'BACKEND_AGNOSTIC FAIL M world/texture path sprites-metal: [1-9][0-9]* textures adopted GL names under backend=metal'

echo "== M2: paintWorldNode adopts the GL name itself =="
mutate "$SG" '  if (cacheEntry.slot.texture == nullptr) return false;
' '  if (cacheEntry.slot.texture == nullptr && cacheEntry.slot.handle != 0) {  // MUTANT M2
    ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888, {srcW, srcH}, 1};
    cacheEntry.slot.texture =
        ImpellerTextureCreateWithOpenGLTextureHandleNew(renderContext_, &desc, cacheEntry.slot.handle);
  }
  if (cacheEntry.slot.texture == nullptr) return false;
'
run M2 'BACKEND_AGNOSTIC FAIL G GL symbol outside the GL backend files: engine/scenegraph/SceneGraph.cpp:[0-9]+: ImpellerTextureCreateWithOpenGLTextureHandleNew'

echo "== M3: the supersample hook runs with backend=metal =="
mutate "$GB" '  b.supersample = useGl ? std::move(gl.supersample) : nullptr;' \
'  b.supersample = std::move(gl.supersample);  // MUTANT M3'
run M3 'BACKEND_AGNOSTIC FAIL M supersample [a-z]+-metal: the supersample hook ran under backend=metal'

echo "== M4: the GL halve hop lost its Y-flip =="
mutate "$SS" '  ImpellerDisplayListBuilderTranslate(b, 0, (float)dstH);
  ImpellerDisplayListBuilderScale(b, 1.0f, -1.0f);
' '  // MUTANT M4: no Y-flip on the halve hop
'
run M4 'BACKEND_AGNOSTIC FAIL P pixels differ from the pre-pass binary: [a-z-]+-ss4'

echo "== M5: --backend metal accepted =="
mutate "$SEL" '    *error = "--backend metal is darwin-only";
    return false;' \
'    (void)error;  // MUTANT M5: metal accepted off darwin'
run M5 'BACKEND_AGNOSTIC FAIL B --backend metal was accepted'

trap - EXIT
restore
rm -rf "$BACKUP"
echo "MUTATE_PASS: all 5 mutants killed by ci-backend-agnostic"
