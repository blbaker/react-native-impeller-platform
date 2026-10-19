#!/usr/bin/env bash
# iOS Task 1.4 mutants for tools/ci-reduce-motion-ios.sh (run on linux):
#   M1  reduceMotion hardcoded false -> M once toggled on
#   M2  increaseContrast read from the wrong switch (reduce transparency) -> C
# Then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-reduce-motion-ios.sh
A11Y=engine/modules/AccessibilitySettingsIOS.mm
mut_backup "$A11Y"

mut_apply "$A11Y" 's.reduceMotion = UIAccessibilityIsReduceMotionEnabled();' \
  's.reduceMotion = false;  // MUTANT M1'
mut_expect M1 "$GATE" 'IOS_REDUCE_MOTION_GATE FAIL M: '

mut_apply "$A11Y" 's.increaseContrast = UIAccessibilityDarkerSystemColorsEnabled();' \
  's.increaseContrast = UIAccessibilityIsReduceTransparencyEnabled();  // MUTANT M2'
mut_expect M2 "$GATE" 'IOS_REDUCE_MOTION_GATE FAIL C: '

mut_restore
mut_clean "$GATE" '^IOS_REDUCE_MOTION_PASS '
mut_summary MUTATION_VERIFY_REDUCE_MOTION_IOS
