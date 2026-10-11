#!/usr/bin/env bash
# Proves tools/ci-modal.sh fails when <Modal> is not an overlay surface:
#   M1 modal painted in-tree (no overlay pass)        -> arm A (later sibling covers it)
#   M2 overlay keeps the modal's own frame origin     -> arm A (content shifted 50,50)
#   M3 hit test ignores the modal                     -> arm D (click reaches the app)
#   M4 onShow never dispatched                        -> arm C
#   M5 onShow sent on every paint                     -> arm C
#   M6 Escape does not reach the modal                -> arm F
#   M7 modal not sized to the window                  -> arm B (opaque container collapses)
set -euo pipefail
cd "$(dirname "$0")/.."
FILES=(engine/scenegraph/SceneGraph.cpp engine/scenegraph/Modal.cpp engine/fabric/FabricHost.cpp engine/fabric/ModalHostShadowNode.h)
BAK="$(mktemp -d)"
for f in "${FILES[@]}"; do mkdir -p "$BAK/$(dirname "$f")"; cp "$f" "$BAK/$f"; done
put_back() { for f in "${FILES[@]}"; do cp "$BAK/$f" "$f"; done; }
restore() { put_back; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || echo "WARN: rebuild of restored tree failed" >&2; rm -rf "$BAK"; }
trap restore EXIT
fail() { echo "MODAL_MUTATION_FAIL: $*" >&2; exit 1; }
mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) == 1, f"mutation anchor not found exactly once in {p}: {old!r}"
open(p, "w").write(s.replace(old, new))
PY
}
check() {  # name, arm letter that must be named in the FAIL line
  bash tools/engine-build.sh linux x64 > "$BAK/$1.build.log" 2>&1 || { tail -5 "$BAK/$1.build.log" >&2; fail "$1 tree did not build"; }
  if bash tools/ci-modal.sh > "$BAK/$1.log" 2>&1; then fail "$1 SURVIVED: gate passed with the mutant in"; fi
  local line; line="$(grep -E '^MODAL_FAIL: ' "$BAK/$1.log" | head -1 || true)"
  echo "$line" | grep -q "FAIL: $2:" || { tail -6 "$BAK/$1.log" >&2; fail "$1 killed, but not by arm $2: $line"; }
  echo "   OK: $1 killed ($line)"
  put_back
}

echo "== control: unmutated tree must PASS =="
bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || fail "control tree did not build"
bash tools/ci-modal.sh > "$BAK/control.log" 2>&1 || { tail -8 "$BAK/control.log" >&2; fail "control FAILED"; }
echo "   OK: control passes"

echo "== M1: modal painted in-tree =="
mutate engine/scenegraph/SceneGraph.cpp "  if (node.isModal && node.tag != modalWalk_) return;
" ""
mutate engine/scenegraph/Modal.cpp "  for (auto r : roots_) collectModalsLocked(r, &modals);
  // Tree order" "  // Tree order"
check M1 A

echo "== M2: overlay keeps the modal's frame origin =="
mutate engine/scenegraph/Modal.cpp "    paintNode(builder, n, -(float)f.origin.x, -(float)f.origin.y);" "    paintNode(builder, n, 0, 0);"
check M2 A

echo "== M3: hit test ignores the modal =="
mutate engine/scenegraph/Modal.cpp "  if (!modals.empty()) {" "  if (false) {"
check M3 D

echo "== M4: onShow never dispatched =="
mutate engine/scenegraph/Modal.cpp "      m->onShow({});" "      (void)m;"
check M4 C

echo "== M5: onShow on every paint =="
mutate engine/scenegraph/Modal.cpp "    if (n.modalShown) continue;
" ""
check M5 C

echo "== M6: Escape does not reach the modal =="
mutate engine/fabric/FabricHost.cpp '  if (key == "Escape" && phase == KeyEventPhase::Down) {' '  if (false) {'
check M6 F

echo "== M7: modal not sized to the window =="
mutate engine/fabric/ModalHostShadowNode.h "    node.setSize(Size{" "    if (false) node.setSize(Size{"
check M7 B
echo "MODAL_MUTATION_PASS"
