#!/usr/bin/env bash
# Proves tools/ci-activity-indicator.sh fails when the spinner is wrong:
#   M1 the head spoke never advances      -> arm B (frame at 1.25 s equals frame 0)
#   M2 an animating spinner is not a live clock -> arm C (the idle loop sleeps)
set -euo pipefail
cd "$(dirname "$0")/.."
FILES=(engine/scenegraph/ActivityIndicator.h engine/host/main.cpp)
BAK="$(mktemp -d)"
for f in "${FILES[@]}"; do mkdir -p "$BAK/$(dirname "$f")"; cp "$f" "$BAK/$f"; done
put_back() { for f in "${FILES[@]}"; do cp "$BAK/$f" "$f"; done; }
restore() { put_back; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || echo "WARN: rebuild of restored tree failed" >&2; rm -rf "$BAK"; }
trap restore EXIT
fail() { echo "ACTIVITY_MUTATION_FAIL: $*" >&2; exit 1; }
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
  if bash tools/ci-activity-indicator.sh > "$BAK/$1.log" 2>&1; then fail "$1 SURVIVED: gate passed with the mutant in"; fi
  local line; line="$(grep -E '^ACTIVITY_INDICATOR_FAIL: ' "$BAK/$1.log" | head -1 || true)"
  echo "$line" | grep -q "FAIL: $2:" || { tail -6 "$BAK/$1.log" >&2; fail "$1 killed, but not by arm $2: $line"; }
  echo "   OK: $1 killed ($line)"
  put_back
}

echo "== control: unmutated tree must PASS =="
bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || fail "control tree did not build"
bash tools/ci-activity-indicator.sh > "$BAK/control.log" 2>&1 || { tail -8 "$BAK/control.log" >&2; fail "control FAILED"; }
echo "   OK: control passes"

echo "== M1: head spoke never advances =="
mutate engine/scenegraph/ActivityIndicator.h "  return static_cast<int>((msSinceStart / kSpinnerStepMs) % kSpinnerSpokes);" "  return 0;"
check M1 B

echo "== M2: animating spinner is not a live clock =="
mutate engine/host/main.cpp "          animatedThisFrame || sceneGraph.focusedTextInput() != 0 ||
          sceneGraph.spinnerAnimating();" "          animatedThisFrame || sceneGraph.focusedTextInput() != 0;"
check M2 C
echo "ACTIVITY_MUTATION_PASS"
