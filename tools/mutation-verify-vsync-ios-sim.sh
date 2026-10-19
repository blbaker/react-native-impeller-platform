#!/usr/bin/env bash
# iOS Task 1.2 mutants for tools/ci-vsync-ios-sim.sh (run on linux):
#   M1  DisplayLinkIOS creates the CADisplayLink but never adds it to a run loop
#       -> T: the gate times out, never "0 frames, 0 jitter"
#   M2  the sink reports twice the real period -> M: mean is 50% off the period
#   M3  the sink drops a third of the callbacks -> J/M: uneven, longer intervals
# Then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-vsync-ios-sim.sh
DL=engine/host/DisplayLinkIOS.mm
mut_backup "$DL"

mut_apply "$DL" '  [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];' \
  '  // MUTANT M1: never added to a run loop'
mut_expect M1 "$GATE" 'IOS_VSYNC_GATE FAIL T: '

mut_apply "$DL" 'const int64_t periodUs = targetUs > nowUs ? targetUs - nowUs : 0;' \
  'const int64_t periodUs = targetUs > nowUs ? (targetUs - nowUs) * 2 : 0;  // MUTANT M2'
mut_expect M2 "$GATE" 'IOS_VSYNC_GATE FAIL M: '

mut_apply "$DL" '  if (!sink) return;
  const int64_t nowUs' '  if (!sink) return;
  static int gDrop = 0;
  if (++gDrop % 3 == 0) return;  // MUTANT M3
  const int64_t nowUs'
mut_expect M3 "$GATE" 'IOS_VSYNC_GATE FAIL (J|M): '

mut_restore
mut_clean "$GATE" '^IOS_VSYNC_PASS '
mut_summary MUTATION_VERIFY_VSYNC_IOS_SIM
