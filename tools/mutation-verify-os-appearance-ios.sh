#!/usr/bin/env bash
# iOS Phase 1 / Task 1.4 mutants for tools/ci-os-appearance-ios.sh (run on linux):
#   M1  DarwinOsScheme (iOS) always answers light -> D: no dark change
#   M2  DarwinRefreshOsScheme (iOS) never re-reads, so the watcher's cached
#       value never moves -> D
# Then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-os-appearance-ios.sh
APP=engine/host/OsAppearanceIOS.mm
mut_backup "$APP"

mut_apply "$APP" 'out = CurrentTraits().userInterfaceStyle == UIUserInterfaceStyleDark ? "dark" : "light";' \
  '(void)CurrentTraits();
    out = "light";  // MUTANT M1'
mut_expect M1 "$GATE" 'IOS_OS_APPEARANCE_GATE FAIL D: '

mut_apply "$APP" '  dispatch_async(dispatch_get_main_queue(), ^{ DarwinOsScheme(); });' \
  '  // MUTANT M2: never re-read'
mut_expect M2 "$GATE" 'IOS_OS_APPEARANCE_GATE FAIL D: '

mut_restore
mut_clean "$GATE" '^IOS_OS_APPEARANCE_PASS '
mut_summary MUTATION_VERIFY_OS_APPEARANCE_IOS
