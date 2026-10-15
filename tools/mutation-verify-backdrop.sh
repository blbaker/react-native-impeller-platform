#!/usr/bin/env bash
# MUTATION TEST for tools/ci-backdrop.sh (FP-41). Each mutant edits ENGINE SOURCE, rebuilds, and
# must turn the gate red for its own reason.
#
#   M1  backdrop null: SaveLayer gets no backdrop filter (pre-FP-41 SceneGraph never passed one),
#       so the layer holds only the tint over a sharp backdrop -> "backdrop not blurred"
#   M2  blur applied to the view's OWN content: the blur rides the layer paint's image filter
#       instead of the backdrop slot, so it blurs the flat tint and leaves what is behind it sharp
#       -> "backdrop not blurred"
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="engine/scenegraph/BackdropBlur.cpp"
BACKUP="$(mktemp -d)"
cp "$SRC" "$BACKUP/BackdropBlur.cpp"
restore() { cp "$BACKUP/BackdropBlur.cpp" "$SRC"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { RNI_BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller" bash tools/ci-backdrop.sh > "$1" 2>&1; }

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
  if ! grep -q 'BACKDROP_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-backdrop stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-200)"
}

ANCHOR='  ImpellerDisplayListBuilderSaveLayer(builder, &box, nullptr, backdrop);'

echo "== M1: backdrop null =="
mutate "$SRC" "$ANCHOR" '  ImpellerDisplayListBuilderSaveLayer(builder, &box, nullptr, nullptr);  // MUTANT M1'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'ss0 blur: backdrop not blurred inside the blur view'
restore

echo "== M2: blur on the view's own content =="
mutate "$SRC" "$ANCHOR" '  ImpellerPaint own = ImpellerPaintNew();  // MUTANT M2: filter the layer, not the backdrop
  ImpellerPaintSetImageFilter(own, backdrop);
  ImpellerDisplayListBuilderSaveLayer(builder, &box, own, nullptr);
  ImpellerPaintRelease(own);'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'ss0 blur: backdrop not blurred inside the blur view'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(grep -o 'BACKDROP_PASS' "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_BACKDROP_OK -- 2 mutants, 2 killed, engine restored and green"
