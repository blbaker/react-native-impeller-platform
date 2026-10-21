#!/usr/bin/env bash
# Mutants for tools/ci-ios-mac-run.sh, run on linux with RNI_MAC_HOST set.
#   M1  RNIEngine never starts the surface: the app runs, nothing draws -> E
#   M2  signed ad hoc instead of by an Apple Development identity with a
#       profile (RNI_MAC_RUN_ADHOC=1): it must not run -> S or L (measured: S,
#       xcodebuild refuses an ad hoc build for "Designed for iPad")
# Then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-ios-mac-run.sh
ENG=engine/ios/RNIEngine.mm
mut_backup "$ENG"

mut_apply "$ENG" '  s.session->StartSurface(s.appName, s.width, s.height, s.scale);' \
  '  // MUTANT M1: the surface is never started'
mut_expect M1 "$GATE" 'IOS_MAC_RUN_GATE FAIL E: '

export RNI_MAC_RUN_ADHOC=1
mut_expect M2 "$GATE" 'IOS_MAC_RUN_GATE FAIL (S|L): '
unset RNI_MAC_RUN_ADHOC

mut_restore
mut_clean "$GATE" '^IOS_MAC_RUN_PASS '
mut_summary MUTATION_VERIFY_IOS_MAC_RUN
