#!/usr/bin/env bash
# Mutation check for tools/ci-style-audit.sh, shadow items 1-4. Each mutant
# breaks ONE piece of the shadow work; the gate must FAIL, and must name the
# tile that mutant breaks (a mutant killed for the wrong tile proves nothing).
#   M1  iOS shadow* props never collected            -> shadowIOS
#   M2  outer shadow offset dropped (centred halo)    -> shadowIOS boxShadow
#   M3  outer shadow blur dropped (hard copy)         -> shadowIOS boxShadow
#   M4  outer shadow painted OVER the box             -> shadowIOS (boxShadow
#       is clipped out of the border box, so its order is invisible: not claimed)
#   M5  inset shadow not clipped to the padding box   -> boxShadowInset
#   M6  inset entries skipped                         -> boxShadowInset
#   M7  `elevation` not parsed by our ViewProps       -> elevation
# Not covered (the fixture cannot see it, so it is not claimed): boxShadow's
# clip-out of the border box, which only shows under a translucent background.
# Sources are restored on exit, whatever happens.
set -euo pipefail
cd "$(dirname "$0")/.."
SG=engine/scenegraph/SceneGraph.cpp
SH=engine/scenegraph/Shadows.cpp
HP=engine/fabric/platform/impeller/react/renderer/components/view/HostPlatformViewProps.cpp
FILES=("$SG" "$SH" "$HP")
BAK="$(mktemp -d)"
for f in "${FILES[@]}"; do mkdir -p "$BAK/$(dirname "$f")"; cp "$f" "$BAK/$f"; done
put_back() { for f in "${FILES[@]}"; do cp "$BAK/$f" "$f"; done; }
restore() {
  put_back
  bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || echo "WARN: rebuild of restored tree failed" >&2
  rm -rf "$BAK"
}
trap restore EXIT
fail() { echo "STYLE_MUTATION_FAIL: $*" >&2; exit 1; }

run_gate() { set +e; bash tools/ci-style-audit.sh > "$1" 2>&1; local rc=$?; set -e; return $rc; }

mutate() {  # FILE OLD NEW: exact replacement, anchor asserted present once
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) == 1, f"mutation anchor not found exactly once in {p}: {old!r}"
open(p, "w").write(s.replace(old, new))
PY
}

check() {  # name, tiles that must be named in the FAIL line
  local name="$1"; shift
  bash tools/engine-build.sh linux x64 > "$BAK/$name.build.log" 2>&1 || { tail -5 "$BAK/$name.build.log" >&2; fail "$name tree did not build"; }
  if run_gate "$BAK/$name.log"; then fail "$name SURVIVED: gate passed with the mutant in"; fi
  local line; line="$(grep -o 'STYLE_AUDIT_GATE_FAIL: .*' "$BAK/$name.log" || true)"
  for t in "$@"; do
    echo "$line" | grep -qw "$t" || { tail -6 "$BAK/$name.log" >&2; fail "$name killed, but not for $t: $line"; }
  done
  echo "   OK: $name killed ($line)"
  put_back
}

echo "== control: unmutated tree must PASS =="
bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || fail "control tree did not build"
run_gate "$BAK/control.log" || { tail -8 "$BAK/control.log" >&2; fail "control FAILED: nothing below means anything"; }
echo "   OK: control passes"

echo "== M1: iOS shadow* props never collected =="
mutate "$SG" "        s.clipOutsideBox = false;
        node.shadows.push_back(s);" "        s.clipOutsideBox = false;
        (void)s;"
check M1 shadowIOS

echo "== M2: outer shadow offset dropped =="
mutate "$SH" "box.x + s.offsetX - s.spread, box.y + s.offsetY - s.spread," "box.x - s.spread, box.y - s.spread,"
check M2 shadowIOS boxShadow

echo "== M3: outer shadow blur dropped =="
mutate "$SH" "  if (s.sigma > 0.0f) {
    ImpellerMaskFilter mf" "  if (false) {
    ImpellerMaskFilter mf"
check M3 shadowIOS boxShadow

echo "== M4: outer shadows painted over the box =="
mutate "$SG" "  if (!node.shadows.empty()) {
    PaintOuterShadows(builder, shadowBox, node.shadows, OwnAlpha(node));
  }" ""
mutate "$SG" "  // Inset boxShadows sit over the background and under the border (CSS)." "  if (!node.shadows.empty()) {
    PaintOuterShadows(builder, shadowBox, node.shadows, OwnAlpha(node));
  }
  // Inset boxShadows sit over the background and under the border (CSS)."
check M4 shadowIOS

echo "== M5: inset shadow not clipped to the padding box =="
mutate "$SH" "    ClipBox(builder, pad, padR, kImpellerClipOperationIntersect);" ""
check M5 boxShadowInset

echo "== M6: inset entries skipped =="
mutate "$SH" "    if (!s.inset || s.color[3] * alpha <= 0.0f) continue;" "    if (true) continue;"
check M6 boxShadowInset

echo "== M7: elevation not parsed =="
mutate "$HP" '          "elevation",' '          "elevationX",'
check M7 elevation

echo "STYLE_MUTATION_PASS (7/7 shadow mutants killed for their own tile)"
