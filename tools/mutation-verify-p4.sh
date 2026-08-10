#!/usr/bin/env bash
# MUTATION VERIFICATION for the P4 module-seam gate.
#
# A gate that has never been seen RED is a hypothesis. This breaks the seam in
# seven specific ways and requires tools/ci-p4.sh to fail on each, then
# restores the tree and requires it to pass again.
#
# THE SHAPE THAT MATTERS HERE IS DIFFERENT FROM P2/P3. Those mutants broke
# PAINTING, so the wrong pixels were the only symptom. A module-seam mutant
# typically leaves the renderer completely healthy: every node mounts, every
# node paints, the frame looks fine, exit code is 0, and no JS exception is
# thrown. The app just silently loses a native capability. That is precisely
# why the fixture converts each module's RESULT into a pixel — there is
# nothing else to look at.
#
# Three of these (M2, M3, M7) are mutations of the JS PACKAGING, not of C++,
# because that is where this phase's real defects were: a flawless native
# module is worth nothing if the JS branches around it.
#
# THE MUTANT MUST ACTUALLY APPLY. Every patch asserts its pattern is present;
# a mutation script whose pattern has drifted leaves the tree UNMUTATED, the
# gate correctly goes green, and the run reports the mutant as UNCAUGHT —
# sending you to debug a gate that is fine.
set -euo pipefail
cd "$(dirname "$0")/.."

REG="engine/runtime/ReactHost.cpp"
PM="engine/modules/PlatformModules.cpp"
PMH="engine/modules/PlatformModules.h"
SHIM="package/src/metro-shims/index.js"
PLAT="package/src/metro-shims/shims/Platform.impeller.js"
ALERT="package/src/metro-shims/shims/Alert.impeller.js"

BACKUP="$(mktemp -d)"
for f in "$REG" "$PM" "$PMH" "$SHIM" "$PLAT" "$ALERT"; do
  cp "$f" "$BACKUP/$(basename "$f")"
done
restore_files_only() {
  for f in "$REG" "$PM" "$PMH" "$SHIM" "$PLAT" "$ALERT"; do
    cp "$BACKUP/$(basename "$f")" "$f"
  done
}
trap 'restore_files_only; rm -rf "$BACKUP"' EXIT

PASSED=0
FAILED=0

# mutate <file> <find> <replace> — fails loudly if <find> is not present.
mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, find, repl = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if find not in s:
    sys.stderr.write("MUTANT DID NOT APPLY — pattern not found in %s:\n%s\n" % (path, find))
    sys.exit(1)
open(path, "w").write(s.replace(find, repl, 1))
PY
}

expect_red() {
  local name="$1"
  echo "--- mutant: $name"
  if bash tools/ci-p4.sh > "$BACKUP/out.log" 2>&1; then
    echo "    ❌ GATE STAYED GREEN — it does not detect: $name"
    FAILED=$((FAILED + 1))
  else
    echo "    ✅ RED: $(grep -m1 -A2 'P4_MODULES_FAIL' "$BACKUP/out.log" | tail -1 | head -c 180)"
    PASSED=$((PASSED + 1))
  fi
  restore_files_only
}

echo "=== baseline must be GREEN before any mutant means anything ==="
bash tools/ci-p4.sh > "$BACKUP/base.log" 2>&1 \
  || { echo "BASELINE IS RED — fix that first:"; tail -20 "$BACKUP/base.log"; exit 1; }
echo "    ✅ baseline green"

# M1 — a module is dropped from the registry. Appearance goes missing, RN's
# Appearance.js falls back to its 'light' default, and NOTHING reports an
# error: no exception, no warning, every node still paints. This is the mutant
# that proves asserting a NON-DEFAULT value matters — a fixture expecting
# 'light' would sail straight through this.
mutate "$REG" \
  '  modules_->add("Appearance", [s = appearance_](auto inv) {
    return std::make_shared<AppearanceModule>(inv, s);
  });' \
  '  // MUTANT: Appearance not registered'
expect_red "M1 Appearance module dropped from the registry (RN falls back to 'light')"

# M2 — THE ALERT.JS BRANCH BUG, restored. Alert.js is not a stub and resolves
# perfectly; it just has no `else` after its ios/android branches, so on this
# platform Alert.alert() never leaves JavaScript. The AlertManager TurboModule
# stays perfect, registered and reachable — the call simply never arrives.
# Caught by the pixel AND by alerts_shown=0.
mutate "$SHIM" \
  "  'react-native/Libraries/Alert/Alert.js': 'Alert.impeller.js'," \
  "  // MUTANT: Alert.js not redirected"
expect_red "M2 Alert.js shim removed (RN's ios/android-only branch silently no-ops)"

# M3 — the ios-stub disease, restored. RCTAlertManager.js is a bare
# `export * from './RCTAlertManager'` that resolves to ITSELF on a custom
# platform, so alertWithArgs is undefined. Distinct from M2 and equally fatal:
# both had to be fixed for Alert to work at all.
mutate "$SHIM" \
  "  'react-native/Libraries/Alert/RCTAlertManager.js': 'RCTAlertManager.ios.js'," \
  "  // MUTANT: RCTAlertManager self-resolves"
expect_red "M3 RCTAlertManager ios-stub redirect removed (self-resolving re-export)"

# M4 — DELEGATION REMOVED. Unknown module names stop falling through to RN's
# own DefaultTurboModules, so NativePerformance (which we never hand-rolled)
# vanishes. Everything we wrote ourselves keeps working perfectly, which is
# what makes this invisible without a probe aimed specifically at a module we
# do NOT own.
mutate "$REG" \
  "    return react::DefaultTurboModules::getTurboModule(name, jsInvoker);" \
  "    return nullptr;  // MUTANT: no delegation"
expect_red "M4 DefaultTurboModules delegation removed (performance disappears)"

# M5 — the openURL allowlist inverted to accept anything with a scheme. This is
# the security mutant: canOpenURL('file:///etc/passwd') starts returning true,
# which on Windows means ShellExecuteW would LAUNCH it. A one-sided fixture
# that only asserted the happy path would stay green.
mutate "$PM" \
  "  if (!allowed) return false;" \
  "  if (!allowed) allowed = true;  // MUTANT: allowlist inverted"
expect_red "M5 openURL allowlist accepts every scheme (file:// would launch on Windows)"

# M6 — the alert callback is never invoked. Native RECORDS the alert
# (alerts_shown=1, so the seam is provably crossed) and simply never calls
# back, leaving the promise inside Alert.js pending forever. The app does not
# crash; it hangs a feature. Only the pixel knows.
mutate "$PM" \
  "  callback.call(rt, jsi::Value(0.0), jsi::String::createFromAscii(rt, \"\"));" \
  "  // MUTANT: callback never invoked"
expect_red "M6 alert callback never fired (native reached, JS promise left pending)"

# M7 — Platform.constants stops reading the TurboModule and returns {} again,
# exactly as it did for two phases. Platform.OS is still 'impeller', the app
# renders identically, and Platform.Version silently reads 0.
mutate "$PLAT" \
  "      this.__constants = NativePlatformConstants
        ? NativePlatformConstants.getConstants()
        : {};" \
  "      this.__constants = {};  // MUTANT: constants never read from native"
expect_red "M7 Platform.constants no longer read from the native module"

echo
echo "=== restoring and re-checking baseline ==="
restore_files_only
bash tools/ci-p4.sh > "$BACKUP/final.log" 2>&1 \
  && echo "    ✅ baseline green again" \
  || { echo "    ❌ tree not restored correctly"; tail -20 "$BACKUP/final.log"; exit 1; }

echo
echo "MUTATION SUMMARY: $PASSED/7 mutants caught"
[ "$FAILED" -eq 0 ] || exit 1
echo "P4_MUTATION_VERIFY_PASS"
