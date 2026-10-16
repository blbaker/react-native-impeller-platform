#!/usr/bin/env bash
# Mutation verification for tools/ci-animate.sh.
#
# A gate is worthless until it has been SEEN RED. This one especially: its whole
# job is to catch a static engine, and the static-engine failure mode is silent
# by construction. If the gate could not actually fail, it would be a green
# check that certifies nothing -- which is worse than no gate, because it ends
# the conversation.
#
# Each mutant breaks the ENGINE (or the fixture), never the checker, so a redden
# proves the gate is measuring the product rather than its own assertions.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable-timeout.sh"  # portable timeout (mac fallback)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MAIN="engine/host/main.cpp"
FIXTURE="fixtures/p9-repaint/index.js"
BACKUP="$(mktemp -d)"
GLFWSURF="engine/host/GlfwSurface.cpp"
GATE="tools/ci-animate.sh"
cp "$MAIN" "$BACKUP/main.cpp"
cp "$FIXTURE" "$BACKUP/index.js"
# ⛔ BACK UP BY COPY, RESTORE BY COPY. An earlier version of this script
# restored mutants with `git checkout -- <file>`, which FAILS on a file that is
# not yet tracked ("pathspec did not match any file"). ci-animate.sh was
# untracked at the time, so the M3 mutant was left IN THE WORKING TREE and the
# suite exited 0 -- a mutation run that silently corrupts the thing it is
# verifying. Never assume a file is committed.
cp "$GLFWSURF" "$BACKUP/GlfwSurface.cpp"
cp "$GATE" "$BACKUP/ci-animate.sh"

restore() {
  cp "$BACKUP/main.cpp" "$MAIN"
  cp "$BACKUP/index.js" "$FIXTURE"
  cp "$BACKUP/GlfwSurface.cpp" "$GLFWSURF"
  cp "$BACKUP/ci-animate.sh" "$GATE"
  bash tools/engine-build.sh > /tmp/mut-restore.log 2>&1 || true
  rm -rf "$BACKUP"
}
trap restore EXIT

PASS=0
TOTAL=0

run_mutant() {
  local name="$1"
  TOTAL=$((TOTAL + 1))
  echo "--- mutant: $name ---"
  if ! bash tools/engine-build.sh > /tmp/mut-build.log 2>&1; then
    echo "  BUILD FAILED -- a mutant that does not compile proves nothing"
    tail -5 /tmp/mut-build.log
    return
  fi
  if DISPLAY="${DISPLAY:-:0}" timeout 500 bash tools/ci-animate.sh > /tmp/mut-gate.log 2>&1; then
    echo "  ⛔ NOT CAUGHT -- gate still passed:"
    grep -E "ANIMATE_GATE|px changed" /tmp/mut-gate.log | sed 's/^/     /'
  else
    echo "  caught:"
    grep -E "ANIMATE_GATE_FAIL|px changed" /tmp/mut-gate.log | sed 's/^/     /'
    PASS=$((PASS + 1))
  fi
  cp "$BACKUP/main.cpp" "$MAIN"
  cp "$BACKUP/index.js" "$FIXTURE"
  cp "$BACKUP/GlfwSurface.cpp" "$GLFWSURF"
  # ⛔ RESTORING THE SOURCE IS NOT RESTORING THE BINARY.
  #
  # Without this rebuild, the NEXT mutant runs against the PREVIOUS mutant's
  # compiled engine. That is exactly what happened: M3 (a gate-only mutation
  # that cannot affect the engine at all) reddened with "anim: no later
  # capture" -- M1's symptom, because M1's repaint-once binary was still
  # installed. The suite reported 2/2 while one mutant was scored for the
  # wrong reason, which is indistinguishable from a real pass in the summary
  # line. Rebuild between mutants, always.
  bash tools/engine-build.sh > /tmp/mut-rebuild.log 2>&1 || true
}

echo "MUTATION_VERIFY_ANIMATE_START"

# M1: the exact pre-P9-A behaviour -- paint one frame, then spin without
# repainting. The window still opens, still exits 0, still runs N frames, so
# ci-window.sh stays GREEN. Only a two-frame pixel comparison can see this.
python3 - <<'PY'
import re
p="engine/host/main.cpp"; s=open(p).read()
s=s.replace("""    surface.pollEvents();
    int painted = paintFrame();""",
"""    surface.pollEvents();
    int painted = (frameIndex == 0) ? paintFrame() : 0;  // MUTANT M1""",1)
open(p,"w").write(s)
PY
run_mutant "M1 repaint once then spin (the pre-P9-A engine)"

# ⛔ M2 IS DELIBERATELY NOT ASSERTED, AND THE REASON IS A REAL LIMIT OF THIS GATE.
#
# The obvious second mutant is "repaint but never swap buffers" -- the on-screen
# freeze a user would actually report. It was written, run, and NOT CAUGHT:
# the gate still reported 12800px changed.
#
# That is correct behaviour, not a gate defect. glReadPixels on a double-
# buffered default framebuffer reads the BACK buffer -- the one we just drew
# into -- so the capture sees new content whether or not it was ever presented.
# And GLES3 cannot read the front buffer of the default framebuffer at all
# (glReadBuffer accepts only GL_BACK there), so there is no readPixels-based
# assertion that could distinguish them. Faking one would mean asserting
# something the API cannot observe.
#
# So state the scope honestly instead of pretending:
#   ci-animate.sh proves THE ENGINE REPAINTS NEW CONTENT EVERY FRAME.
#   It does NOT prove those frames reach the screen.
# Presentation is covered by the window actually appearing (tools/window-spike.sh,
# screenshot-verified) and would need an off-process screen capture to gate.
# A known gap.

# M3: vacuity check on the CONTROL. Make the "static" fixture animate too; the
# negative assertion must then fail. Without this, a gate whose control silently
# animated would report a meaningless pass.
python3 - <<'PY'
p="tools/ci-animate.sh"; s=open(p).read()
s=s.replace('build_app "P3Fixture" "$ROOT/fixtures/p3-conformance" "$WORK/static"',
            'build_app "P9Repaint" "$ROOT/fixtures/p9-repaint" "$WORK/static"',1)
s=s.replace('capture_pair "$WORK/static" "static" "P3Fixture"',
            'capture_pair "$WORK/static" "static" "P9Repaint"',1)
open(p,"w").write(s)
PY
TOTAL=$((TOTAL + 1))
echo "--- mutant: M3 control fixture animates (vacuity check) ---"
if DISPLAY="${DISPLAY:-:0}" timeout 500 bash tools/ci-animate.sh > /tmp/mut-gate.log 2>&1; then
  echo "  ⛔ NOT CAUGHT -- the negative control is vacuous"
else
  echo "  caught:"; grep -E "ANIMATE_GATE_FAIL" /tmp/mut-gate.log | sed 's/^/     /'
  PASS=$((PASS + 1))
fi
cp "$BACKUP/ci-animate.sh" "$GATE"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_ANIMATE_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_ANIMATE_FAIL ($PASS/$TOTAL)"
  exit 1
fi
