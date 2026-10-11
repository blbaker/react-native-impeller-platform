#!/usr/bin/env bash
# ENG-13: prove tools/ci-svg-dash.sh FAILS when any one piece of the dash
# support is removed. Each mutant edits the live tree, rebuilds, runs the gate,
# restores. The arm that must catch it:
#   M1 strokeDasharray is never read (solid stroke)               -> B
#   M2 paint strokes the undashed path                            -> B
#   M3 strokeDashoffset is ignored                                -> C
#   M4 a negative offset is not wrapped into the pattern          -> D
#   M5 a zero-length dash paints no dot with round caps           -> F
#   M6 a closed path's held-back first dash is never drawn        -> J
#   M7 a closed path never joins its last dash to its first       -> K
#   M8 curve length measured as the chord (fewer, longer dashes)  -> J
#   M9 the offset is left out of the per-icon cache key (N=1)     -> L at N=1
# Not claimed (no mutant would be killed, by design):
#   - native odd-count doubling: react-native-svg's extractStroke already
#     doubles odd lists in JS, so the native copy is unreachable from a bundle.
#   - removing the negative-value guard: the walk then never advances, the dash
#     budget runs out and the stroke falls back to SOLID, which is what the
#     guard produces anyway.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
SD="engine/svg/SvgDash.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SG"; cp "$SD" "$BACKUP/SD"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
LOG="${MV_LOG_DIR:-$BACKUP}"
restore() { cp "$BACKUP/SG" "$SG"; cp "$BACKUP/SD" "$SD"; }
trap 'restore; eval "$BUILD_CMD" > "$LOG/restore.log" 2>&1 || true' EXIT

PASS=0; TOTAL=0
mutate() {  # $1 file  $2 old  $3 new  (exact, must occur exactly once)
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
n = s.count(old)
assert n == 1, f"anchor found {n}x in {p}: {old[:60]!r}"
open(p, "w").write(s.replace(old, new))
PY
}
run_mutant() {  # $1 name  $2 ERE the FAIL line must match
  TOTAL=$((TOTAL + 1))
  echo "--- $1"
  if ! eval "$BUILD_CMD" > "$LOG/build.log" 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' "$LOG/build.log" | head -3 | sed 's/^/     /'
  elif bash tools/ci-svg-dash.sh > "$LOG/gate.log" 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "SVG_DASH_GATE_FAIL: ($2)" "$LOG/gate.log"; then
    echo "   caught: $(grep SVG_DASH_GATE_FAIL "$LOG/gate.log" | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep SVG_DASH_GATE_FAIL "$LOG/gate.log" | head -1 | sed 's/^/     /'
  fi
  restore
}

echo "MUTATION_VERIFY_SVG_DASH_START"

mutate "$SG" "  node.svgStrokeDash = svgDashFromDynamic(pp->strokeDasharray);" \
             "  node.svgStrokeDash.clear();  // MUTANT M1"
run_mutant "M1 strokeDasharray never read" "N=0: .*FAIL B"

mutate "$SG" "                builder, dashed != nullptr ? dashed : path, strokePaint);" \
             "                builder, path, strokePaint);  // MUTANT M2"
run_mutant "M2 paint strokes the undashed path" "N=0: .*FAIL B"

mutate "$SG" "  node.svgStrokeDashOffset = (float)pp->strokeDashoffset;" \
             "  node.svgStrokeDashOffset = 0.0f;  // MUTANT M3"
run_mutant "M3 strokeDashoffset ignored" "N=0: .*FAIL C"

mutate "$SD" "  if (off < 0.0) off += sum;" \
             "  // MUTANT M4: negative offset not wrapped"
run_mutant "M4 negative offset not wrapped" "N=0: .*FAIL D"

mutate "$SD" "          if (capDots) em.dot(m, pos);" \
             "          (void)capDots;  // MUTANT M5"
run_mutant "M5 zero-length dash paints no dot" "N=0: .*FAIL F"

mutate "$SD" "      if (take > kEps) em.piece(m, 0.0, take);" \
             "      (void)take;  // MUTANT M6"
run_mutant "M6 held-back first dash never drawn" "N=0: .*FAIL J"

mutate "$SD" "  const bool joinFirst = sp.closed && st.on() && st.remain > kEps;" \
             "  const bool joinFirst = false && sp.closed;  // MUTANT M7"
run_mutant "M7 closed path never joins" "N=0: .*FAIL K"

mutate "$SD" "  m.len = m.cum[kSamples];" \
             "  m.len = std::hypot(s.p[s.kind].x - s.p[0].x, s.p[s.kind].y - s.p[0].y);  // MUTANT M8"
run_mutant "M8 curve length = chord" "N=0: .*FAIL J"

mutate "$SG" '      std::snprintf(buf, sizeof(buf), "@%.3f,c%d;", n.svgStrokeDashOffset,
                    n.svgStrokeLinecap);
      key += buf;' \
             "      // MUTANT M9: offset not in the per-icon cache key"
run_mutant "M9 offset not in the cache key" "N=1: .*FAIL L"

echo "caught $PASS / $TOTAL"
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "SVG_DASH_MUTATION_PASS"
else
  echo "SVG_DASH_MUTATION_FAIL"
  exit 1
fi
