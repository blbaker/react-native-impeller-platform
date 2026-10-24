#!/usr/bin/env bash
# Mutation verification for tools/ci-gradient-cache.sh (ENG-48).
#
# Each mutant removes ONE field from the per-<Svg> cache key's paint-server
# segment (SceneGraph::appendPaintServerKey) and must be caught by the arm
# that isolates that field. Restore by cp + touch (never cp -p: an old mtime
# lets ninja keep the mutant's object) and REBUILD between mutants.
#
# Not mutated, on purpose (no pixel arm can see them, so a catch would be a
# false certificate):
#   - gradientTransform: makeGradientSource does not apply it (keyed for later).
#   - the stroke segment: url(#id) STROKES paint nothing in this engine yet.
#   - "=miss" vs "=0": a dangling url(#id) and a non-ref brush with no colour
#     both paint nothing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable-timeout.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SceneGraph.cpp"
LOGS="${MUT_LOGS:-$(mktemp -d)}"
restore_src() { cp "$BACKUP/SceneGraph.cpp" "$SG"; touch "$SG"; }
on_exit() {
  restore_src
  bash tools/engine-build.sh linux x64 > "$LOGS/restore-build.log" 2>&1 || true
  trap - EXIT
  rm -rf "$BACKUP"
}
trap on_exit EXIT

PASS=0
TOTAL=0
ONLY="${ONLY:-}"
want() { [ -z "$ONLY" ] || case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

mutate() {  # python replacement: old new (exact, must match once)
  MUT_OLD="$1" MUT_NEW="$2" python3 -c '
import os, sys
p = "engine/scenegraph/SceneGraph.cpp"
s = open(p).read()
old, new = os.environ["MUT_OLD"], os.environ["MUT_NEW"]
n = s.count(old)
if n != 1:
    sys.exit("mutant anchor found %dx (want 1): %r" % (n, old[:80]))
open(p, "w").write(s.replace(old, new, 1))
'
}

run_mutant() {  # id expected-ERE description
  local id="$1" expect="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  echo "--- $id: $desc ---"
  if ! bash tools/engine-build.sh linux x64 > "$LOGS/$id-build.log" 2>&1; then
    echo "  BUILD FAILED -- a mutant that does not compile proves nothing"
    grep -E "error:" "$LOGS/$id-build.log" | head -3 | sed 's/^/     /'
  elif timeout 600 bash tools/ci-gradient-cache.sh > "$LOGS/$id-gate.log" 2>&1; then
    echo "  NOT CAUGHT -- gate still passed"
  else
    local line
    line="$(grep -E 'GRADIENT_CACHE_GATE_FAIL' "$LOGS/$id-gate.log" | head -1)"
    if echo "$line" | grep -Eq "$expect"; then
      echo "  caught: $line"
      PASS=$((PASS + 1))
    else
      echo "  killed, but not by the expected assertion /$expect/:"
      echo "     ${line:-$(tail -2 "$LOGS/$id-gate.log")}"
    fi
  fi
  restore_src
}

echo "MUTATION_VERIFY_GRADIENT_CACHE_START (logs: $LOGS)"

if want M1; then
mutate '      appendPaintServerKey(key, "fg", n.svgFillIsRef, n.svgFillRef);
' '      // MUTANT M1: fill paint server dropped from the key
'
run_mutant M1 '^GRADIENT_CACHE_GATE_FAIL: pair: slot Q is red-rising' \
  "fill gradient not in the key (0.8.5 as shipped)"
fi

if want M2; then
mutate '  const SceneNode& g = *git->second;
' '  key += ref; key += ";"; return;  // MUTANT M2: key by id, not content
  const SceneNode& g = *git->second;
'
run_mutant M2 'twins: offscreens=2, want 1|restop' \
  "key by gradient id instead of content"
fi

if want M3; then
mutate '  for (float v : g.svgGradientCoords) {
    std::snprintf(buf, sizeof(buf), "%.9g,", v);
    key += buf;
  }
' '  // MUTANT M3: coords dropped
'
run_mutant M3 '^GRADIENT_CACHE_GATE_FAIL: coords' "gradient coordinates not in the key"
fi

if want M4; then
mutate "g.svgGradientRadial ? 'r' : 'l', g.svgGradientUnits);" \
       "g.svgGradientRadial ? 'r' : 'l', 0);  // MUTANT M4: units dropped"
run_mutant M4 '^GRADIENT_CACHE_GATE_FAIL: units' "gradientUnits not in the key"
fi

if want M5; then
mutate "g.svgGradientRadial ? 'r' : 'l', g.svgGradientUnits);" \
       "'l', g.svgGradientUnits);  // MUTANT M5: kind dropped"
run_mutant M5 '^GRADIENT_CACHE_GATE_FAIL: kind' "linear/radial not in the key"
fi

if want M6; then
mutate 'std::snprintf(buf, sizeof(buf), "%.9g@%08x,", st[i], (unsigned)argb);' \
       'std::snprintf(buf, sizeof(buf), "%.9g,", st[i]); (void)argb;  // MUTANT M6: stop colour dropped'
run_mutant M6 '^GRADIENT_CACHE_GATE_FAIL: pair: slot Q is red-rising' \
  "stop colours (incl. stop opacity) not in the key"
fi

if want M7; then
mutate 'std::snprintf(buf, sizeof(buf), "%.9g@%08x,", st[i], (unsigned)argb);' \
       'std::snprintf(buf, sizeof(buf), "@%08x,", (unsigned)argb);  // MUTANT M7: stop offset dropped'
run_mutant M7 '^GRADIENT_CACHE_GATE_FAIL: offsets' "stop offsets not in the key"
fi

echo
if [ "$PASS" -eq "$TOTAL" ] && [ -z "$ONLY" ]; then
  echo "MUTATION_VERIFY_GRADIENT_CACHE_PASS ($PASS/$TOTAL)"
elif [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_GRADIENT_CACHE_PARTIAL_PASS ($PASS/$TOTAL, ONLY=$ONLY)"
else
  echo "MUTATION_VERIFY_GRADIENT_CACHE_FAIL ($PASS/$TOTAL)"
  exit 1
fi
