#!/usr/bin/env bash
# MUTATION VERIFICATION for the P2 gate.
#
# A gate that has never been seen RED is a hypothesis. This breaks the engine in
# five specific ways and requires tools/ci-p2.sh to fail on each, then restores
# the tree and requires it to pass again.
#
# The mutants are chosen so that at least two of them leave EVERY OTHER SIGNAL
# HEALTHY — exit code 0, no JS error, a full mutation log, a plausible frame —
# so passing them would prove the gate reads pixels and structure rather than
# process exit codes.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

SG="engine/scenegraph/SceneGraph.cpp"
TLM="engine/text/ImpellerTextLayoutManager.cpp"
SHIMS="package/src/metro-shims/index.js"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SceneGraph.cpp"
cp "$TLM" "$BACKUP/ImpellerTextLayoutManager.cpp"
cp "$SHIMS" "$BACKUP/index.js"
restore() {
  cp "$BACKUP/SceneGraph.cpp" "$SG"
  cp "$BACKUP/ImpellerTextLayoutManager.cpp" "$TLM"
  cp "$BACKUP/index.js" "$SHIMS"
  rm -rf "$BACKUP"
}
trap restore EXIT

PASSED=0
FAILED=0

expect_red() {
  local name="$1"
  echo "--- mutant: $name"
  if bash tools/ci-p2.sh > "$BACKUP/out.log" 2>&1; then
    echo "    ❌ GATE STAYED GREEN — it does not detect: $name"
    FAILED=$((FAILED + 1))
  else
    echo "    ✅ RED: $(grep -m1 'P2_MOUNT_FAIL' "$BACKUP/out.log" | head -c 160)"
    PASSED=$((PASSED + 1))
  fi
  restore_files_only
}
restore_files_only() {
  cp "$BACKUP/SceneGraph.cpp" "$SG"
  cp "$BACKUP/ImpellerTextLayoutManager.cpp" "$TLM"
  cp "$BACKUP/index.js" "$SHIMS"
}

echo "=== baseline must be GREEN before any mutant means anything ==="
bash tools/ci-p2.sh > "$BACKUP/base.log" 2>&1 \
  || { echo "BASELINE IS RED — fix that first:"; tail -20 "$BACKUP/base.log"; exit 1; }
echo "    ✅ baseline green"

# M1 — the tree mounts perfectly and nothing is drawn. Exit 0, no JS error,
# mutation log complete. Only pixels catch it.
python3 - "$SG" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
s = s.replace("  ++painted_;\n  ImpellerPaint paint = ImpellerPaintNew();",
              "  ++painted_;\n  if (true) { return; }\n  ImpellerPaint paint = ImpellerPaintNew();", 1)
open(p, "w").write(s)
PY
expect_red "M1 paintNode draws nothing (tree intact, exit 0)"

# M2 — every View drawn as a plain rect. Three of four colour probes still pass
# and the frame looks right in a thumbnail; only the corner probe can see it.
python3 - "$SG" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("if (node.borderRadius > 0.0f) {\n      ImpellerRoundingRadii radii = {};",
              "if (false) {\n      ImpellerRoundingRadii radii = {};", 1)
open(p, "w").write(s)
PY
expect_red "M2 rounded rects drawn square (only the corner probe sees it)"

# M3 — the root-adoption regression this phase actually hit: nodes exist,
# painted_nodes drops to 0.
python3 - "$SG" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("        auto& node = nodes_[tag];\n        updateFromShadowView(node, m.newChildShadowView);",
              "        if (auto it = nodes_.find(tag); it != nodes_.end()) {\n          updateFromShadowView(it->second, m.newChildShadowView);\n        }", 1)
open(p, "w").write(s)
PY
expect_red "M3 Update is find-not-upsert (surface root never enters the tree)"

# M4 — text measures 0x0, i.e. RN's cxx stub behaviour restored. Boxes all still
# pass; only the ink band notices the label vanished.
python3 - "$TLM" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("  float width = ImpellerParagraphGetLongestLineWidth(paragraph);",
              "  float width = 0; (void)ImpellerParagraphGetLongestLineWidth(paragraph);", 1)
s = s.replace("  float height = ImpellerParagraphGetHeight(paragraph);",
              "  float height = 0; (void)ImpellerParagraphGetHeight(paragraph);", 1)
open(p, "w").write(s)
PY
expect_red "M4 TextLayoutManager returns 0x0 (the RN cxx-stub failure)"

# M5 — the packaging half: drop the BaseViewConfig platform-fork redirect and
# the bundle dies at mount. Proves the gate still covers the consumer path.
python3 - "$SHIMS" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("const PLATFORM_FORKED = {\n  'react-native/Libraries/NativeComponent/BaseViewConfig.js': 'BaseViewConfig.ios.js',\n};",
              "const PLATFORM_FORKED = {};", 1)
open(p, "w").write(s)
PY
expect_red "M5 BaseViewConfig fork-redirect removed (ios-stub disease returns)"

echo
echo "=== restoring and re-checking baseline ==="
restore_files_only
bash tools/ci-p2.sh > "$BACKUP/final.log" 2>&1 \
  && echo "    ✅ baseline green again" \
  || { echo "    ❌ tree not restored correctly"; tail -20 "$BACKUP/final.log"; exit 1; }

echo
echo "MUTATION SUMMARY: $PASSED/5 mutants caught"
[ "$FAILED" -eq 0 ] || exit 1
echo "P2_MUTATION_VERIFY_PASS"
