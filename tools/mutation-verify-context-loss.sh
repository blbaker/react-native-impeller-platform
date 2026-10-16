#!/usr/bin/env bash
# MUTATION TEST for tools/ci-context-loss.sh (FP-32). Each mutant edits ENGINE
# SOURCE, rebuilds, and must turn the gate red for its own reason.
#
#   M1  skip texture re-upload: the image cache keeps the textures of the lost
#       context (no Clear, so nothing re-uploads from the decoded pixels) ->
#       arm A: the image box differs after every recovery
#   M2  keep a stale typography context: the rebuild releases the old paint
#       context but leaves it bound -> arm S (ASan): the next text paint
#       reads the freed context (libimpeller is not instrumented, so ASan sees
#       a SEGV inside ImpellerParagraphBuilderBuildParagraphNew called from
#       SceneGraph::buildRunParagraph; a use-after-free when it is)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN

FILES=(engine/scenegraph/SceneGraphContextLoss.cpp engine/host/GlfwSurfaceRebuild.cpp)
BACKUP="$(mktemp -d)"
for f in "${FILES[@]}"; do cp "$f" "$BACKUP/$(basename "$f")"; done
restore() { for f in "${FILES[@]}"; do cp "$BACKUP/$(basename "$f")" "$f"; done; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { CTX_LOSS_ARMS="$1" bash tools/ci-context-loss.sh > "$2" 2>&1; }

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
  if grep -q 'CONTEXT_LOSS_PASS' "$2" || ! grep -q 'CONTEXT_LOSS_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-context-loss stayed GREEN" >&2; tail -5 "$2" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 FAIL "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | cut -c1-240)"
}

echo "== M1: skip texture re-upload (image cache keeps the lost context's textures) =="
mutate engine/scenegraph/SceneGraphContextLoss.cpp '  const size_t images = imageTextures_.Clear();' '  const size_t images = 1;  // MUTANT M1: stale image textures, no re-upload'
build "$BACKUP/m1-build.log"; gate A "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" "A: loss 1: none of the 3 presents after the recovery matches the pre-loss frame.*'image': [1-9]"
restore

echo "== M2: stale typography context (released, still bound) =="
mutate engine/host/GlfwSurfaceRebuild.cpp '  rni::typography::Unbind(old);
  rni::typography::Bind(fresh);
  typography_ = fresh;' '  typography_ = fresh;  // MUTANT M2: the released context stays bound'
build "$BACKUP/m2-build.log"; gate S "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'S: sanitizer report under forced context loss: ERROR: AddressSanitizer: (heap-use-after-free|SEGV)[A-Za-z -]* at  in rni::SceneGraph::buildRun'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "A B C S" "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(tail -1 "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATION_VERIFY_CONTEXT_LOSS_PASS"
