#!/usr/bin/env bash
# MUTATION TEST for tools/ci-platform-view.sh (FP-44). Each mutant edits ENGINE
# SOURCE, rebuilds, and must turn the gate red for its own reason.
#
#   M1  one frame late: the embedder applies the PREVIOUS frame's view params
#       (position lag) -> the native window sits at the last frame's box
#   M2  clip ignored: the clip window is the whole box, not box ∩ clip -> the
#       native view shows outside the scroll viewport
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN

FILES=(engine/host/PlatformViewsX11Gl.cpp)
BACKUP="$(mktemp -d)"
for f in "${FILES[@]}"; do cp "$f" "$BACKUP/$(basename "$f")"; done
restore() { for f in "${FILES[@]}"; do cp "$BACKUP/$(basename "$f")" "$f"; done; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-platform-view.sh > "$1" 2>&1; }

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
  if grep -q 'PLATFORM_VIEW_PASS' "$2" || ! grep -q 'PLATFORM_VIEW_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-platform-view stayed GREEN" >&2; tail -5 "$2" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 FAIL "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | cut -c1-220)"
}

echo "== M1: one frame late (previous frame's params applied) =="
mutate engine/host/PlatformViewsX11Gl.cpp '    std::shared_ptr<PlatformViewFrame> apply = frame;' '    std::shared_ptr<PlatformViewFrame> apply = last_ ? last_ : frame;  // MUTANT M1'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" "A: present [0-9]+: native view at .* is the previous frame's box, this frame's is .* \(one frame late\)"
restore

echo "== M2: clip ignored (clip window = the whole box) =="
mutate engine/host/PlatformViewsX11Gl.cpp '        const PvRect vis = v.clipped ? v.box.Intersect(v.clip) : v.box;' '        const PvRect vis = v.box;  // MUTANT M2'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" "A: present [0-9]+: native view .* covers more than this frame's visible box .* \(clip ignored\)"
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(tail -1 "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATION_VERIFY_PLATFORM_VIEW_PASS"
