#!/usr/bin/env bash
# mutation-verify-expo-dev — prove tools/ci-expo-dev.sh can FAIL.
#   M1  the Expo platform patch is not applied      -> expo start rejects 'impeller' (loud guard, HTTP 500)
#   M2  patch AND loud guard gone (the pre-fix code) -> every module resolves as ios
#   M3  the engine never calls HMRClient.setup       -> the edit is never hot-applied
# Edits the live tree (restored on exit) and M3 rebuilds the staged engine.
# Run it on its own (systemd unit), not beside other gates.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"
SHIM=package/src/metro-shims/index.js; RH=engine/runtime/ReactHost.cpp
BAK="$(mktemp -d)"; cp "$SHIM" "$BAK/shim.js"; cp "$RH" "$BAK/ReactHost.cpp"
put_back() { cp "$BAK/shim.js" "$SHIM"; cp "$BAK/ReactHost.cpp" "$RH"; }
restore() {
  put_back
  bash tools/engine-build.sh > /dev/null 2>&1 || echo "WARN: rebuild of restored tree failed" >&2
  rm -rf "$BAK"
}
trap restore EXIT
fail() { echo "EXPO_DEV_MUTATION_FAIL: $*" >&2; exit 1; }
run_gate() { set +e; bash tools/ci-expo-dev.sh > "$1" 2>&1; local rc=$?; set -e; return $rc; }
mutate() { python3 tools/expo_mutate.py "$1" "$2" "$3" || fail "anchor not found: $2"; }
KILLED=0
check() {  # name expected-failure-substring [rebuild]
  if [ "${3:-}" = rebuild ]; then
    bash tools/engine-build.sh > "$BAK/$1.build.log" 2>&1 || { tail -15 "$BAK/$1.build.log" >&2; fail "$1 tree did not build"; }
  fi
  if run_gate "$BAK/$1.log"; then fail "$1 SURVIVED: gate passed with the mutant in"; fi
  grep -qF -- "$2" "$BAK/$1.log" || { tail -6 "$BAK/$1.log" >&2; fail "$1 killed by the WRONG assertion (wanted: $2)"; }
  echo "   OK: $1 killed ($(grep -o 'EXPO_DEV_GATE_FAIL: .*' "$BAK/$1.log" | cut -c1-120))"
  KILLED=$((KILLED + 1))
  put_back
}

echo "== control: unmutated tree must PASS =="
bash tools/engine-build.sh > "$BAK/control.build.log" 2>&1 || fail "control tree did not build"
run_gate "$BAK/control.log" || { tail -8 "$BAK/control.log" >&2; fail "control FAILED: nothing below means anything"; }
echo "   OK: control passes"

echo "== M1: Expo's platform lookup is not taught 'impeller' =="
mutate "$SHIM" "  teachExpoImpellerPlatform(config.projectRoot || process.cwd());" "  // (mutant) no teachExpoImpellerPlatform"
check M1 "1: dev bundle HTTP 500"

echo "== M2: the pre-fix resolver (no patch, retry-as-ios swallows the platform error) =="
mutate "$SHIM" "  teachExpoImpellerPlatform(config.projectRoot || process.cwd());" "  // (mutant) no teachExpoImpellerPlatform"
mutate "$SHIM" "      if (/platform \"impeller\"/.test(String(error && error.message))) {" "      if (false) {"
check M2 "expo start resolved the bundle as ios"

echo "== M3: the engine never sets up HMR =="
mutate "$RH" '  instance_->callFunctionOnModule("HMRClient", "setup", std::move(args));' '  (void)args;'
check M3 "3: editing App.js did not re-render the app" rebuild

[ "$KILLED" -eq 3 ] || fail "only $KILLED/3 mutants ran"
echo "EXPO_DEV_MUTATION_PASS (3/3 mutants killed by their own assertion)"
