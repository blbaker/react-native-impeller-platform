#!/usr/bin/env bash
# Mutation verification for tools/ci-usesym.sh.
#
# ⛔ WHY THIS GATE ESPECIALLY NEEDS TO BE SEEN RED.
#
# The bug it was written for was not "nothing painted" -- it was the definition
# painting ONCE, IN THE WRONG PLACE, with a clean log and a complete-looking
# screen. A gate against that is easy to write in a way that is green for the
# wrong reason: check only the <Use> sites and you miss the leak; check only the
# leak site and you miss a <Use> that never resolves. So the mutants below break
# each half INDEPENDENTLY, and both must be caught.
#
# ⚠️ Restore by COPY and REBUILD between mutants (same rule as
# mutation-verify-svg.sh): restoring source without rebuilding scores the next
# mutant against the previous mutant's binary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
FH="engine/fabric/FabricHost.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SceneGraph.cpp"
cp "$FH" "$BACKUP/FabricHost.cpp"

restore_src() {
  cp "$BACKUP/SceneGraph.cpp" "$SG"
  cp "$BACKUP/FabricHost.cpp" "$FH"
}
trap 'restore_src; bash tools/engine-build.sh > /tmp/musesym-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

PASS=0
TOTAL=0

run_mutant() {
  local name="$1"
  TOTAL=$((TOTAL + 1))
  echo "--- mutant: $name ---"
  if ! bash tools/engine-build.sh > /tmp/musesym-build.log 2>&1; then
    echo "  BUILD FAILED -- a mutant that does not compile proves nothing"
    grep -E "error:" /tmp/musesym-build.log | head -3 | sed 's/^/     /'
  elif timeout 500 bash tools/ci-usesym.sh > /tmp/musesym-gate.log 2>&1; then
    echo "  ⛔ NOT CAUGHT -- gate still passed:"
    grep -E "USESYM_GATE_PASS|control=" /tmp/musesym-gate.log | sed 's/^/     /'
  else
    echo "  caught:"
    grep -E "USESYM_GATE_FAIL" /tmp/musesym-gate.log | head -2 | sed 's/^/     /'
    PASS=$((PASS + 1))
  fi
  restore_src
  bash tools/engine-build.sh > /tmp/musesym-rebuild.log 2>&1 || true
}

echo "MUTATION_VERIFY_USESYM_START"

# M1: THE ORIGINAL BUG, re-introduced. Drop the definition-subtree early return
# so the painter walks into <Defs>/<Symbol> again. The <Use> sites still paint
# correctly, so a gate that only asserted "the logo appears" stays green -- only
# the bare-leak-site assertion can see this.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("""  if (node.isSvgDefinition) return;""",
            """  if (false && node.isSvgDefinition) return;  // MUTANT M1: the leak""",1)
open(p,"w").write(s)
PY
run_mutant "M1 <Defs>/<Symbol> painted at the definition site (the shipped bug)"

# M2: never resolve the href. Every <Use> becomes a no-op, which is what the mac
# agent BELIEVED was happening. The leak site stays bare, so the leak assertion
# passes and only the use-site ink assertion can catch it.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("""    auto def = svgDefs_.find(node.svgUseHref);""",
            """    auto def = svgDefs_.end();  // MUTANT M2: href never resolves""",1)
open(p,"w").write(s)
PY
run_mutant "M2 <Use href> never resolves (the assumed behaviour)"

# M3 WAS: "leading '#' not stripped from href". It SURVIVED, and it was right to.
# I had asserted in a source comment that rnsvg passes href through with its
# hash. It does not: elements/Use.js matches against idPattern and forwards
# capture group 1, so C++ receives "hostapp-sig", not "#hostapp-sig". The strip in
# SceneGraph.cpp is defensive, not load-bearing, and a mutant that removes
# dead-but-harmless code SHOULD survive. Removed rather than weakened, and the
# wrong comment it was defending has been corrected. Recorded here because a
# deleted mutant with no explanation looks like a gate being made easier.

# M3: unregister RNSVGSymbol. It mounts as a plain view, the cast to
# RNSVGSymbolProps returns null, so the id and viewBox are never read and no
# definition is ever registered. Every <Use> then dangles. Clean log throughout.
python3 - <<'PY'
p="engine/fabric/FabricHost.cpp"; s=open(p).read()
s=s.replace("""      react::concreteComponentDescriptorProvider<react::RNSVGSymbolComponentDescriptor>());""",
            """      react::concreteComponentDescriptorProvider<react::RNSVGGroupComponentDescriptor>());  // MUTANT M3""",1)
open(p,"w").write(s)
PY
run_mutant "M3 RNSVGSymbol unregistered (id/viewBox never read, every Use dangles)"

# M4: unregister RNSVGUse from the provider registry while leaving everything
# else intact. It still mounts, its props arrive as plain ViewProps, the
# dynamic_cast to RNSVGUseProps returns null, href is never read. Clean log.
python3 - <<'PY'
p="engine/fabric/FabricHost.cpp"; s=open(p).read()
s=s.replace("""      react::concreteComponentDescriptorProvider<react::RNSVGUseComponentDescriptor>());""",
            """      react::concreteComponentDescriptorProvider<react::RNSVGGroupComponentDescriptor>());  // MUTANT M4""",1)
open(p,"w").write(s)
PY
run_mutant "M4 RNSVGUse unregistered (mounts, casts to null, logs clean)"

# M5: drop the viewBox->instance scale, keeping only the translate. The logo
# appears at every mounting site in the right colour at the right origin, just
# at the SYMBOL's authoring size. This mutant SURVIVED the first cut of the
# gate, because every <Use> in that fixture was mounted at the symbol's own size
# so the scale factor was 1.0 and dropping it was a no-op. The fixture now has a
# 40x40 instance of an 80x80 symbol, with a matched inside/outside probe pair.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("""        sx = node.svgUseBox[2] / target.svgSymbolViewBox[2];
        sy = node.svgUseBox[3] / target.svgSymbolViewBox[3];""",
            """        sx = 1.0f; sy = 1.0f;  // MUTANT M5: viewBox scale dropped""",1)
open(p,"w").write(s)
PY
run_mutant "M5 viewBox->instance scale dropped (asset paints at authoring size)"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_USESYM_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_USESYM_FAIL ($PASS/$TOTAL)"
  exit 1
fi
