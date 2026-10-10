#!/usr/bin/env bash
# Mutation check for tools/ci-style-coverage.sh (and the grid-1 tiles judged by
# tools/ci-style-audit.sh). Each mutant breaks ONE landed fix; the gates must
# FAIL and the FAIL line must NAME the tile that fix landed (a mutant killed
# for the wrong tile proves nothing). Mutants are tagged with their pass id
# (SC01a, SC01b, ...) so tools/style-fix-check.sh can run one pass's set:
#   ONLY=SC01a,SC01b bash tools/mutation-verify-style-coverage.sh
# Sources are restored (and the engine rebuilt) on exit, whatever happens.
#
# Mutant index (keep in step with the blocks below):
#   SC00a  border colour alpha dropped (opaque border)   -> g2:borderAlphaOverBg
#   SC01a  Text paints at the frame origin (insets dropped) -> g2:textBoxStyle
#   SC02a  TextInput paint ignores contentInsets.left -> g2:tiPadding
#   SC03a  width without colour paints nothing -> g2:borderNoColor
#   SC04a  mixed rounded border drops the outer radius clip -> g2:roundedPerSideWidthColor
#   SC04b  mixed rounded border drops the inner cutout -> g2:radiusUnevenWidth
set -euo pipefail
cd "$(dirname "$0")/.."
# Every file any mutant edits. Add yours here.
FILES=(engine/scenegraph/SceneGraph.cpp engine/scenegraph/Shadows.cpp
       engine/text/TextStyle.h engine/text/ImpellerTextLayoutManager.cpp
       engine/fabric/FabricHost.cpp engine/scenegraph/BorderDash.h)
for f in engine/scenegraph/*.cpp engine/scenegraph/*.h engine/text/*.h engine/text/*.cpp \
         engine/modules/*.h engine/modules/*.cpp engine/host/*.cpp package/src/metro-shims/shims/*.js \
         package/src/metro-shims/index.js; do
  [ -f "$f" ] && FILES+=("$f")
done
BAK="$(mktemp -d)"
for f in "${FILES[@]}"; do mkdir -p "$BAK/$(dirname "$f")"; cp "$f" "$BAK/$f"; done
put_back() { for f in "${FILES[@]}"; do cp "$BAK/$f" "$f"; done; }
restore() {
  put_back
  bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || echo "WARN: rebuild of restored tree failed" >&2
  rm -rf "$BAK"
}
trap restore EXIT
fail() { echo "STYLE_COVERAGE_MUTATION_FAIL: $*" >&2; exit 1; }
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]; }

# Both gates; the FAIL line of whichever fails first is what check() reads.
run_gate() {
  set +e
  { bash tools/ci-style-coverage.sh && bash tools/ci-style-audit.sh; } > "$1" 2>&1
  local rc=$?; set -e; return $rc
}

mutate() {  # FILE OLD NEW: exact replacement, anchor asserted present once
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) == 1, f"mutation anchor not found exactly once in {p}: {old!r}"
open(p, "w").write(s.replace(old, new))
PY
}

# Package (JS) mutants need the probe bundles rebuilt to take effect; such a
# mutant calls `rebundle` after `mutate` (needs node; WSL only).
rebundle() {
  bash tools/build-style-coverage-bundles.sh > "$BAK/rebundle.log" 2>&1 \
    || { tail -5 "$BAK/rebundle.log" >&2; fail "rebundle failed"; }
  REBUNDLED=1
}

check() {  # name, tiles that must be named in the FAIL line
  local name="$1"; shift
  bash tools/engine-build.sh linux x64 > "$BAK/$name.build.log" 2>&1 \
    || { tail -5 "$BAK/$name.build.log" >&2; fail "$name tree did not build"; }
  if run_gate "$BAK/$name.log"; then fail "$name SURVIVED: gates passed with the mutant in"; fi
  local line; line="$(grep -oE 'STYLE_(COVERAGE|AUDIT)_GATE_FAIL: .*' "$BAK/$name.log" | head -1 || true)"
  for t in "$@"; do
    echo "$line" | grep -qF -- "$t" || { tail -6 "$BAK/$name.log" >&2; fail "$name killed, but not for $t: $line"; }
  done
  echo "   OK: $name killed ($line)"
  put_back
  [ -z "${REBUNDLED:-}" ] || { git checkout -- fixtures/*/prebuilt/ 2>/dev/null; REBUNDLED=; }
}

echo "== control: unmutated tree must PASS =="
bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || fail "control tree did not build"
run_gate "$BAK/control.log" || { tail -8 "$BAK/control.log" >&2; fail "control FAILED: nothing below means anything"; }
echo "   OK: control passes"
N=0

# ---- mutants (append new blocks at the end; keep blocks UNINDENTED so
# multi-line anchors match the source byte for byte) ----

if want SC00a; then
echo "== SC00a: border colour alpha dropped =="
mutate engine/scenegraph/SceneGraph.cpp "      if (colors[i]) colorToFloats(colors[i], node.borderColors[i]);" "      if (colors[i]) { colorToFloats(colors[i], node.borderColors[i]); node.borderColors[i][3] = 1.0f; }"
check SC00a g2:borderAlphaOverBg; N=$((N + 1))
fi

if want SC01a; then
echo "== SC01a: Text paints at the frame origin =="
mutate engine/scenegraph/SceneGraph.cpp "const float px = x + (float)pins.left, py = y + (float)pins.top;" "const float px = x, py = y;"
check SC01a g2:textBoxStyle; N=$((N + 1))
fi

if want SC02a; then
echo "== SC02a: TextInput paints at the default pad only =="
mutate engine/scenegraph/SceneGraph.cpp "return kTextInputPad + (float)node.layoutMetrics.contentInsets.left;" "return kTextInputPad;"
check SC02a g2:tiPadding; N=$((N + 1))
fi

if want SC03a; then
echo "== SC03a: width without colour paints nothing =="
mutate engine/scenegraph/SceneGraph.cpp "node.hasBorderColors[i] = (bool)colors[i] || widths[i] > 0;" "node.hasBorderColors[i] = (bool)colors[i];"
check SC03a g2:borderNoColor; N=$((N + 1))
fi

if want SC04a; then
echo "== SC04a: mixed rounded border without the outer radius clip =="
mutate engine/scenegraph/BorderRounded.cpp "ImpellerDisplayListBuilderClipRoundedRect(builder, &outer, &radii,
                                            kImpellerClipOperationIntersect);" "(void)radii;"
check SC04a g2:roundedPerSideWidthColor; N=$((N + 1))
fi

if want SC04b; then
echo "== SC04b: mixed rounded border thickness ignores the per-edge width =="
mutate engine/scenegraph/BorderRounded.cpp "const float t = widths[0], r = widths[1], b = widths[2], l = widths[3];" "const float t = widths[3], r = widths[3], b = widths[3], l = widths[3];"
check SC04b g2:radiusUnevenWidth; N=$((N + 1))
fi

if [ -n "${ONLY:-}" ]; then
  echo "STYLE_COVERAGE_MUTATION_PARTIAL_PASS ($N mutant(s) of ONLY=$ONLY killed for their own tile)"
else
  echo "STYLE_COVERAGE_MUTATION_PASS ($N mutants killed for their own tile)"
fi
