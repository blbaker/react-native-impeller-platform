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
#   M8  secure value painted in clear                 -> textInputSecure
#   M9  secureTextEntry never read from props         -> textInputSecure
#   M10 secure Copy/Cut not refused                   -> clipboard (arm C)
#   M11 rounded box clips its square frame            -> overflowRounded
#   M12 fontWeight not applied at MEASURE             -> fontWeight (bold wraps)
#   M13 fontWeight not applied at paint               -> fontWeight fontWeightBold
#   M14 textAlign center/right swapped                -> textAlignCenter/Right
#   M15 underline drawn as line-through               -> underline (tile 41's
#       control is an underline too, so it moves with the mutant: 41 judges
#       colour + style against its control, 39 judges position)
#   M16 decoration colour ignored                     -> decorationColor
#   M17 dashed style dropped alone                    -> decorationColor
# Not covered (the fixture cannot see it, so it is not claimed): boxShadow's
# clip-out of the border box, which only shows under a translucent background;
# the secure caret/selection offsets mapped through the mask (the caret stays
# right of the bullets either way).
# Sources are restored on exit, whatever happens.
set -euo pipefail
cd "$(dirname "$0")/.."
SG=engine/scenegraph/SceneGraph.cpp
SH=engine/scenegraph/Shadows.cpp
HP=engine/fabric/platform/impeller/react/renderer/components/view/HostPlatformViewProps.cpp
FH=engine/fabric/FabricHost.cpp
TL=engine/text/ImpellerTextLayoutManager.cpp
TS=engine/text/TextStyle.h
FILES=("$SG" "$SH" "$HP" "$FH" "$TL" "$TS")
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

# ONLY=M15,M16 runs just those mutants (after the control). For resuming a
# run that stopped part-way; a full run (no ONLY) is what proves the gate.
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]; }

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

if want M1; then
echo "== M1: iOS shadow* props never collected =="
mutate "$SG" "        s.clipOutsideBox = false;
        node.shadows.push_back(s);" "        s.clipOutsideBox = false;
        (void)s;"
check M1 shadowIOS
fi

if want M2; then
echo "== M2: outer shadow offset dropped =="
mutate "$SH" "box.x + s.offsetX - s.spread, box.y + s.offsetY - s.spread," "box.x - s.spread, box.y - s.spread,"
check M2 shadowIOS boxShadow
fi

if want M3; then
echo "== M3: outer shadow blur dropped =="
mutate "$SH" "  if (s.sigma > 0.0f) {
    ImpellerMaskFilter mf" "  if (false) {
    ImpellerMaskFilter mf"
check M3 shadowIOS boxShadow
fi

if want M4; then
echo "== M4: outer shadows painted over the box =="
mutate "$SG" "  if (!node.shadows.empty()) {
    PaintOuterShadows(builder, shadowBox, node.shadows, OwnAlpha(node));
  }" ""
mutate "$SG" "  // Inset boxShadows sit over the background and under the border (CSS)." "  if (!node.shadows.empty()) {
    PaintOuterShadows(builder, shadowBox, node.shadows, OwnAlpha(node));
  }
  // Inset boxShadows sit over the background and under the border (CSS)."
check M4 shadowIOS
fi

if want M5; then
echo "== M5: inset shadow not clipped to the padding box =="
mutate "$SH" "    ClipBox(builder, pad, padR, kImpellerClipOperationIntersect);" ""
check M5 boxShadowInset
fi

if want M6; then
echo "== M6: inset entries skipped =="
mutate "$SH" "    if (!s.inset || s.color[3] * alpha <= 0.0f) continue;" "    if (true) continue;"
check M6 boxShadowInset
fi

if want M7; then
echo "== M7: elevation not parsed =="
mutate "$HP" '          "elevation",' '          "elevationX",'
check M7 elevation
fi

if want M8; then
echo "== M8: secure field painted in clear (mask dropped from paint) =="
mutate "$SG" "const std::string shown = node.tiSecure ? SecureMask(rawShown) : rawShown;" "const std::string shown = rawShown;"
check M8 textInputSecure
fi

if want M9; then
echo "== M9: secureTextEntry never read from props =="
mutate "$SG" "        node.tiSecure = itp->traits.secureTextEntry;" "        (void)itp;"
check M9 textInputSecure
fi

if want M10; then
echo "== M10: secure field Copy/Cut not refused =="
mutate "$FH" "      sceneGraph_->isSecureTextInput(tag)) {" "      false) {"
check M10 clipboard
fi

if want M11; then
echo "== M11: overflow hidden clips the SQUARE frame on a rounded box =="
mutate "$SG" "    if (rounded) {
      ImpellerDisplayListBuilderClipRoundedRect" "    if (false) {
      ImpellerDisplayListBuilderClipRoundedRect"
check M11 overflowRounded
fi

if want M12; then
echo "== M12: fontWeight applied at paint only (measure ignores it) =="
mutate "$TL" "    ApplyFontWeight(style, attrs.fontWeight.has_value() ? (int)*attrs.fontWeight : 0);" "    (void)attrs.fontWeight;"
check M12 fontWeight
fi

if want M13; then
echo "== M13: fontWeight never applied at paint =="
mutate "$SG" "    ApplyFontWeight(style, node.fontWeight);" "    (void)node.fontWeight;"
check M13 fontWeight fontWeightBold
fi

if want M14; then
echo "== M14: textAlign center and right swapped =="
mutate "$TS" "    case 2: a = kImpellerTextAlignmentCenter; break;
    case 3: a = kImpellerTextAlignmentRight; break;" "    case 2: a = kImpellerTextAlignmentRight; break;
    case 3: a = kImpellerTextAlignmentCenter; break;"
check M14 textAlignCenter textAlignRight
fi

if want M15; then
echo "== M15: underline drawn as line-through =="
mutate "$TS" "  if (decoLine == 1 || decoLine == 3) types |= kImpellerTextDecorationTypeUnderline;" "  if (decoLine == 1 || decoLine == 3) types |= kImpellerTextDecorationTypeLineThrough;"
check M15 underline
fi

if want M16; then
echo "== M16: textDecorationColor ignored (decoration in the text colour) =="
mutate "$SG" "                        impellerColor(node.hasDecoColor ? node.decoColor" "                        impellerColor(false ? node.decoColor"
check M16 decorationColor
fi

if want M17; then
echo "== M17: dashed style dropped alone (red but solid) =="
mutate "$TS" "    case 3: d.style = kImpellerTextDecorationStyleDashed; break;" "    case 3: d.style = kImpellerTextDecorationStyleSolid; break;"
check M17 decorationColor
fi

if [ -n "${ONLY:-}" ]; then
  echo "STYLE_MUTATION_PARTIAL_PASS (ONLY=$ONLY killed for their own tile; not a full run)"
else
  echo "STYLE_MUTATION_PASS (17/17 mutants killed for their own tile: shadows 1-4, secure 11, rounded clip 13, weight 5, align 7, decoration 9)"
fi
