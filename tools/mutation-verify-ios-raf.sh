#!/usr/bin/env bash
# Mutants for tools/ci-ios-raf.sh (requestAnimationFrame paced to RNIEngine's
# display link), run on linux with RNI_MAC_HOST set; each mutated tree is
# synced by the gate.
#   M1  RNIEngine never attaches the frame loop: rAF stays on the 16 ms timer,
#       which also runs about 60/s -> F (mode=timer), not R
#   M2  attached, but the frame loop never calls beginAnimationFrame: rAF
#       requests wait for a frame that never flushes them -> C / R
# Then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-ios-raf.sh
ENG=engine/ios/RNIEngine.mm
mut_backup "$ENG"

mut_apply "$ENG" '  s.session->reactHost().attachAnimationFramesToLoop([] {});' \
  '  // MUTANT M1: rAF never attached to the display link'
mut_expect M1 "$GATE" 'IOS_RAF_GATE FAIL F: mode is .timer., not frame'

mut_apply "$ENG" '  s.session->reactHost().beginAnimationFrame();' \
  '  // MUTANT M2: the frame loop never flushes rAF'
mut_expect M2 "$GATE" 'IOS_RAF_GATE FAIL (C|R): '

mut_restore
mut_clean "$GATE" '^IOS_RAF_PASS '
mut_summary MUTATION_VERIFY_IOS_RAF
