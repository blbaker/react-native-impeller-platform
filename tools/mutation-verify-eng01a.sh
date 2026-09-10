#!/usr/bin/env bash
# Mutation-verify the ENG-01a scoping gate. A gate nobody has watched FAIL is
# decoration -- and this one guards a defect that is INVISIBLE to every pixel
# gate we own, so "it passed" is worth nothing until it has been seen to fail.
#
#   M1  resolver ignores originModulePath  -> Platform swaps bundle-wide
#   M2  forged shim leaks into select()    -> select({impeller,ios}) yields ios
#   M3  redirect dropped entirely          -> TextInput.js renders null again
#
# Mutations are applied to a COPY, never to the working tree.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$PWD"
FAILED=0
IDX="package/src/metro-shims/index.js"
SHIM="package/src/metro-shims/shims/Platform.impeller-as-ios.js"

run_case() {  # name expect_pass mutate_fn
  local name="$1" expect="$2" fn="$3"
  local work; work="$(mktemp -d)"
  cp -r "$SRC/package" "$SRC/tools" "$work/"
  ( cd "$work" && "$fn" )
  local log="$work/gate.log" rc=0
  ( cd "$work" && node tools/eng01a-scoping-assert.js ) > "$log" 2>&1 || rc=$?
  local got="FAIL"; grep -q ENG01A_SCOPING_PASS "$log" && got="PASS"
  local why; why="$(grep -m1 ENG01A_SCOPING_FAIL "$log" || true)"
  if [ "$got" = "$expect" ]; then
    printf '  %-4s %-44s %s  %s\n' "OK" "$name" "$got" "${why#ENG01A_SCOPING_FAIL: }"
    rm -rf "$work"
  else
    printf '  %-4s %-44s expected %s got %s\n' "BAD" "$name" "$expect" "$got"
    echo "     log: $log"; tail -20 "$log" | sed 's/^/     /'
    FAILED=1
  fi
}

baseline() { :; }

m1_origin_blind() {
  python3 - "$IDX" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = """  const origin = toPosix(originModulePath);
  for (const [suffix, shim] of Object.entries(IOS_BRANCHED_IMPORTERS)) {
    if (origin.endsWith(suffix)) return path.join(SHIM_DIR, shim);
  }
  return null;"""
assert old in s, "M1 target not found"
open(p, "w").write(s.replace(old, "  return path.join(SHIM_DIR, 'Platform.impeller-as-ios.js');"))
PY
}

m2_select_leaks() {
  python3 - "$SHIM" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "PlatformAsIos.select = Platform.select.bind(Platform);"
assert old in s, "M2 target not found"
open(p, "w").write(s.replace(old, "PlatformAsIos.select = spec => ('ios' in spec ? spec.ios : spec.default);"))
PY
}

m3_no_redirect() {
  python3 - "$IDX" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "  'react-native/Libraries/Components/TextInput/TextInput.js':\n    'Platform.impeller-as-ios.js',\n"
assert old in s, "M3 target not found"
open(p, "w").write(s.replace(old, ""))
PY
}

echo "== ENG-01a scoping: mutation verification =="
run_case "baseline (unmutated)"                 PASS baseline
run_case "M1 resolver ignores originModulePath" FAIL m1_origin_blind
run_case "M2 forged shim leaks into select()"   FAIL m2_select_leaks
run_case "M3 redirect dropped entirely"         FAIL m3_no_redirect

[ "$FAILED" = 0 ] && echo "ENG01A_MUTATION_PASS" || { echo "ENG01A_MUTATION_FAIL"; exit 1; }
