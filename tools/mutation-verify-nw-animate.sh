#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-nw-animate.sh (SC-26). Each mutant breaks
# the package's reanimated stub, rebundles fixtures/sc26-nw-animate, and must
# FAIL the gate with the FAIL line naming the tile it breaks. Needs node + npm.
#   SC26a  createAnimatedComponent is the identity again   -> spinPaused
#   SC26b  animation-delay ignored                         -> pulsePaused
#   SC26c  CSS transitions jump to the new value           -> transitionColors
#   SC26d  withTiming lands on its target at once          -> ref
#   SC26e  withSequence runs only its last step            -> seq
#   SC26f  withRepeat ignores reverse                      -> repeat
#   SC26g  withDelay ignores the delay                     -> delay
#   SC26h  withSpring jumps to its target                  -> spring
#   SC26i  inline animations in useAnimatedStyle jump      -> inline
# ONLY=SC26a,SC26c runs a subset.
set -euo pipefail
cd "$(dirname "$0")/.."
D=package/src/metro-shims/shims/reanimated
FILES=("$D/component.js" "$D/css.js" "$D/values.js" "$D/hooks.js")
BAK="$(mktemp -d)"
for f in "${FILES[@]}"; do cp "$f" "$BAK/$(basename "$f")"; done
restore() { for f in "${FILES[@]}"; do cp "$BAK/$(basename "$f")" "$f"; done; }
trap restore EXIT
fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]; }

mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "mutant anchor not found exactly once in %s: %r" % (p, old[:80])
open(p, "w").write(s.replace(old, new, 1))
PY
}
run_gate() {  # log [skip arm A]
  NW_FIX="$PWD/fixtures/sc26-nw-animate" bash tools/build-nativewind-bundle.sh "$BAK/m.bundle" > "$BAK/build.log" 2>&1 \
    || { tail -5 "$BAK/build.log" >&2; fail "rebundle"; }
  set +e; NW_ANIMATE_SKIP_A="${2:-0}" RNI_TEST_BUNDLE="$BAK/m.bundle" bash tools/ci-nw-animate.sh > "$1" 2>&1; set -e
}
N=0
check() {  # name tile
  run_gate "$BAK/$1.log" 1
  grep -q NW_ANIMATE_GATE_PASS "$BAK/$1.log" && fail "$1 SURVIVED"
  grep -qE "NW_ANIMATE_GATE_FAIL: .*(B: |;)$2:" "$BAK/$1.log" \
    || { tail -5 "$BAK/$1.log" >&2; fail "$1 killed by the wrong assertion (wanted $2)"; }
  echo "   OK: $1 killed -> $2"
  restore; N=$((N + 1))
}

echo "== control =="
run_gate "$BAK/control.log"
grep -q NW_ANIMATE_GATE_PASS "$BAK/control.log" || { tail -8 "$BAK/control.log" >&2; fail "control fails"; }
echo "   OK: control passes"

if want SC26a; then
echo "== SC26a: createAnimatedComponent is the identity =="
mutate "$D/component.js" "  if (cache.has(Component)) return cache.get(Component);" "  return Component;"
check SC26a spinPaused
fi

if want SC26b; then
echo "== SC26b: animation-delay ignored =="
mutate "$D/css.js" "  const delay = nth(css.animationDelay, i, 0);" "  const delay = 0;"
check SC26b pulsePaused
fi

if want SC26c; then
echo "== SC26c: transitions jump =="
mutate "$D/css.js" "      if (duration > 0) {" "      if (false) {"
check SC26c transitionColors
fi

if want SC26d; then
echo "== SC26d: withTiming lands at once =="
mutate "$D/values.js" "      const p = duration <= 0 ? 1 : Math.min(1, (t - this.t0) / duration);" "      const p = 1;"
check SC26d ref
fi

if want SC26e; then
echo "== SC26e: withSequence runs only its last step =="
mutate "$D/values.js" "  const list = inners.map(toAnim);" "  const list = inners.slice(-1).map(toAnim);"
check SC26e seq
fi

if want SC26f; then
echo "== SC26f: withRepeat ignores reverse =="
mutate "$D/values.js" "      if (reverse && 'toValue' in a)" "      if (false && 'toValue' in a)"
check SC26f repeat
fi

if want SC26g; then
echo "== SC26g: withDelay ignores the delay =="
mutate "$D/values.js" "        a.start(this.from, this.t0 + delayMs);" "        a.start(this.from, this.t0);"
check SC26g delay
fi

if want SC26h; then
echo "== SC26h: withSpring jumps =="
mutate "$D/values.js" "      this.current = overshot || rest ? to : this.x;" "      this.current = to;"
check SC26h spring
fi

if want SC26i; then
echo "== SC26i: inline animations jump =="
mutate "$D/hooks.js" "        sv.value = v;" "        sv.value = v.toValue;"
check SC26i inline
fi

echo "MUTATION_VERIFY_PASS ($N mutants killed)"
