#!/usr/bin/env bash
# MUTATION TEST for tools/ci-paragraph-cache.sh. Each mutant edits ENGINE
# SOURCE, rebuilds, and must turn the gate red for its own reason.
#
#   M1  key ignores the runs (text, colour, size, ...)  -> arm C (stale frame)
#   M2  key ignores the text alpha                       -> arm C
#   M3  key ignores the layout width                     -> arm C
#   M4  key ignores textAlign (a node-level input)       -> arm C
#   M5  the cache never hits (every Get builds)          -> arm A (misses)
#   M6  paint bypasses the cache (buildRunParagraph)     -> arm A (hits)
#   M7  minFontScale compared with plain == (NaN != NaN on every <Text>
#       without adjustsFontSizeToFit: the first cut of this cache never hit)
#                                                        -> arm A (misses)
#
# Not covered here: the font-epoch key (a font registered mid-run). No fixture
# adds a font after the first paint; say so rather than claim it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CACHE="engine/scenegraph/ParagraphCache.cpp"
SG="engine/scenegraph/SceneGraph.cpp"
BACKUP="$(mktemp -d)"
cp "$CACHE" "$BACKUP/ParagraphCache.cpp"
cp "$SG" "$BACKUP/SceneGraph.cpp"
# cp + touch, never cp -p: an older mtime than the mutant's object makes ninja
# skip the rebuild and the mutant stays linked in.
restore() {
  cp "$BACKUP/ParagraphCache.cpp" "$CACHE"; touch "$CACHE"
  cp "$BACKUP/SceneGraph.cpp" "$SG"; touch "$SG"
}
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

case "$(uname -s)" in Darwin) PKG=engine-darwin-arm64 ;; *) PKG=engine-linux-x64 ;; esac
build() { bash tools/engine-build.sh > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { RNI_BIN="$ROOT/packages-engine/$PKG/bin/rn-impeller" bash tools/ci-paragraph-cache.sh > "$1" 2>&1; }

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
  if ! grep -q 'PARA_CACHE_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-paragraph-cache stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-160)"
}

run() {  # name file old new ERE
  echo "== $1 =="
  mutate "$2" "$3" "$4"
  build "$BACKUP/$1-build.log"; gate "$BACKUP/$1.log" || true
  expect_killed "$1" "$BACKUP/$1.log" "$5"
  restore
}

STALE='C: cached final frame differs from uncached'
run M1 "$CACHE" '         e.runs == node.runs;' '         true;  // MUTANT M1' "$STALE"
run M2 "$CACHE" 'Same(e.width, w) && Same(e.alpha, alpha) &&' 'Same(e.width, w) &&  /* MUTANT M2 */' "$STALE"
run M3 "$CACHE" 'Same(e.width, w) && Same(e.alpha, alpha) &&' 'Same(e.alpha, alpha) &&  /* MUTANT M3 */' "$STALE"
run M4 "$CACHE" 'e.textAlign == node.textAlign && ' '/* MUTANT M4 */ ' "$STALE"
run M5 "$CACHE" 'if (!Enabled() || drawop::Current() != nullptr) {' 'if (true) {  // MUTANT M5' \
  'A: cached misses=[0-9]+ > 320'
run M6 "$SG" 'paintParagraph(node, std::max(0.0f, w - (float)(pins.left + pins.right)));' \
  'buildRunParagraph(node, std::max(0.0f, w - (float)(pins.left + pins.right)));  // MUTANT M6' \
  'A: cached hits=[0-9]+ < 30000|A control: uncached misses'
run M7 "$CACHE" 'Same(e.minFontScale, node.minFontScale)' 'e.minFontScale == node.minFontScale /* MUTANT M7 */' \
  'A: cached misses=[0-9]+ > 320'

echo "== RESTORE: clean engine must be GREEN =="
restore
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -5 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: restored engine is not green" >&2; exit 1; }
grep -q PARA_CACHE_PASS "$BACKUP/final.log" || { echo "MUTATE_FAIL: restored engine is not green" >&2; exit 1; }
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATION_VERIFY_PARAGRAPH_CACHE_PASS (7/7 killed, clean engine green)"
