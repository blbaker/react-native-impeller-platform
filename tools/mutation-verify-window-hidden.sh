#!/usr/bin/env bash
# Prove tools/ci-window-hidden.sh can FAIL. Each mutant edits the engine,
# rebuilds the staged linux binary, runs the gate and requires a FAIL whose
# message names the defect. The tree is restored and rebuilt on exit.
#   M1 the GLFW_VISIBLE=false hint is dropped (the window is created mapped):
#      the engine's fail-closed check or its own readback must stop the run.
#   M2 main.cpp never hands the flag to the surface (surface.setHidden gone):
#      no engine-side check runs at all, so only the INDEPENDENT X11 oracle
#      can catch the mapped window.
# Darwin-only behaviour (the 1x pin of a 2x backing store, activation policy)
# cannot be reached on linux, where framebuffer == window size; it is checked
# on the Mac (see the gate's arm B and the commit message), not claimed here.
# Prints WINDOW_HIDDEN_MUTATION_PASS.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"
FILES=(engine/host/GlfwSurface.cpp engine/host/main.cpp)
BK="$(mktemp -d)"
for f in "${FILES[@]}"; do mkdir -p "$BK/$(dirname "$f")"; cp -p "$f" "$BK/$f"; done
# ⛔ RESTORE WITH A FRESH MTIME (cp, then touch), NEVER cp -p. ninja rebuilds
# only when a source is NEWER than its object; the original's old mtime is
# older than the mutant's object, so a cp -p restore leaves the mutant linked
# into the staged binary and every later gate tests a broken engine.
put_back() { for f in "${FILES[@]}"; do cp "$BK/$f" "$f"; touch "$f"; done; }
restore() {
  put_back
  bash tools/engine-build.sh linux x64 > /tmp/wh-mut-restore.log 2>&1 || echo "RESTORE BUILD FAILED (see /tmp/wh-mut-restore.log)" >&2
}
trap restore EXIT

mutate() {  # file, old, new  (exact, must match once)
  python3 - "$1" "$2" "$3" <<'EOF'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
n = s.count(old)
assert n == 1, f"anchor found {n}x in {p}: {old!r}"
open(p, "w").write(s.replace(old, new))
EOF
}
expect_killed() {  # name, ERE the FAIL line must match
  local name="$1" want="$2"
  bash tools/engine-build.sh linux x64 > "/tmp/wh-mut-$name-build.log" 2>&1 || { echo "$name: build failed" >&2; exit 1; }
  if bash tools/ci-window-hidden.sh > "/tmp/wh-mut-$name.log" 2>&1; then
    echo "$name: SURVIVED (the gate passed on a broken engine)" >&2; exit 1
  fi
  local why; why="$(grep -m1 'WINDOW_HIDDEN_FAIL' "/tmp/wh-mut-$name.log" || true)"
  echo "$name: killed -> $why"
  echo "$why" | grep -qiE "$want" || { echo "$name: killed, but not by the expected assertion ($want)" >&2; exit 1; }
  put_back
}

mutate engine/host/GlfwSurface.cpp '    glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE);
' '    // MUTANT M1: hint dropped
'
expect_killed M1 'A: (engine run failed|no RN_IMPELLER_WINDOW_OK|a window was viewable|the engine saw)'
grep -q 'the window was created visible' /tmp/wh-mut-M1.log \
  || { echo "M1: the engine's fail-closed check did not fire" >&2; exit 1; }
echo "M1: engine log: $(grep -m1 'created visible' /tmp/wh-mut-M1.log)"

mutate engine/host/main.cpp '  surface.setHidden(gWindowHidden);  // before init: --window-hidden
' '  // MUTANT M2: flag never reaches the surface
'
expect_killed M2 'A: a window was viewable'

echo "WINDOW_HIDDEN_MUTATION_PASS (2 mutants killed)"
