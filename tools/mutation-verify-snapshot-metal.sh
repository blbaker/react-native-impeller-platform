#!/usr/bin/env bash
# ENG-47 mutation check for the Metal snapshot readback (darwin only).
# Proves tools/ci-snapshot.sh arm M (headless --backend metal, same readback as
# the Metal window) FAILS when the Metal readback is missing or wrong:
#
#   MM1  no Metal readback wired (the npm 0.8.2 state)   -> captures reject
#   MM2  BGRA bytes passed through as RGBA               -> colours differ
#   MM3  rows bottom-up (a GL-style flip on Metal)       -> upside down
#
# Each mutant rebuilds the darwin engine (tools/engine-build.sh darwin arm64),
# runs arm M, and must be killed for its own reason. Sources are restored with
# cp (a fresh mtime, so ninja rebuilds) and the clean engine must pass again.
# Runs no window: arm M is headless.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# Pin the gate to the binary engine-build.sh darwin arm64 stages. ci-snapshot.sh
# defaults to the linux-x64 path, so an unset RNI_BIN made the clean control
# fail with "no engine binary" before any mutant ran.
export RNI_BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
[ "$(uname -s)" = Darwin ] || { echo "MUTATE_FAIL: darwin only (the Metal readback is compiled on darwin)" >&2; exit 1; }

FILES=(engine/scenegraph/SnapshotReadbackMetal.mm engine/scenegraph/GpuBackend.cpp)
BACKUP="$(mktemp -d)"
for f in "${FILES[@]}"; do cp "$f" "$BACKUP/$(basename "$f")"; done
restore() { for f in "${FILES[@]}"; do cp "$BACKUP/$(basename "$f")" "$f"; done; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh darwin arm64)" >&2' EXIT

build() { bash tools/engine-build.sh darwin arm64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { SNAPSHOT_ARMS=M bash tools/ci-snapshot.sh > "$1" 2>&1; }

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
  if grep -q 'SNAPSHOT_PASS' "$2" || ! grep -q 'SNAPSHOT_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-snapshot arm M stayed GREEN" >&2; tail -5 "$2" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 FAIL "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | cut -c1-220)"
}

echo "== control: clean engine, arm M must be GREEN =="
build "$BACKUP/control-build.log"
gate "$BACKUP/control.log" || { tail -15 "$BACKUP/control.log" >&2; echo "MUTATE_FAIL: arm M RED on the clean tree" >&2; exit 1; }
grep -q 'readback=metal' "$BACKUP/control.log" || { echo "MUTATE_FAIL: control did not run on the Metal readback" >&2; exit 1; }
echo "   $(tail -1 "$BACKUP/control.log")"

echo "== MM1: no Metal readback (0.8.2) =="
mutate engine/scenegraph/GpuBackend.cpp \
  '  if (context == GpuBackend::kMetal) b.snapshot = MakeMetalSnapshotReadback(ctx);' \
  '  (void)MakeMetalSnapshotReadback;  // MUTANT MM1: Metal has no readback'
build "$BACKUP/mm1-build.log"; gate "$BACKUP/mm1.log" || true
expect_killed MM1 "$BACKUP/mm1.log" 'M: JS did not finish: .*render backend on this host'
restore

echo "== MM2: BGRA passed through as RGBA =="
mutate engine/scenegraph/SnapshotReadbackMetal.mm \
  '    if (layout == kImpellerReadbackLayoutBGRA8888) {' \
  '    if (false && layout == kImpellerReadbackLayoutBGRA8888) {  // MUTANT MM2'
build "$BACKUP/mm2-build.log"; gate "$BACKUP/mm2.log" || true
expect_killed MM2 "$BACKUP/mm2.log" 'M: (capture differs from the on-screen crop|the red marker is not)'
restore

echo "== MM3: rows bottom-up =="
mutate engine/scenegraph/SnapshotReadbackMetal.mm \
  '    *rgba = std::move(raw);' \
  '    for (int y = 0; y < h / 2; ++y)  // MUTANT MM3: a GL-style flip on Metal
      std::swap_ranges(raw.begin() + (size_t)y * w * 4, raw.begin() + (size_t)(y + 1) * w * 4,
                       raw.begin() + (size_t)(h - 1 - y) * w * 4);
    *rgba = std::move(raw);'
build "$BACKUP/mm3-build.log"; gate "$BACKUP/mm3.log" || true
expect_killed MM3 "$BACKUP/mm3.log" 'M: capture is upside down'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(tail -1 "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATION_VERIFY_SNAPSHOT_METAL_PASS"
