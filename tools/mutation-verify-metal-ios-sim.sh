#!/usr/bin/env bash
# iOS Task 1.1 mutants for tools/ci-metal-ios-sim.sh (run on linux;
# each mutated tree is synced to the Mac by the gate itself):
#   M1  the test host draws a plain rect, not a rounded one
#       -> R: corner_aa=0, too few colors
#   M2  MetalSurfaceIOS::Present never calls ImpellerSurfacePresent (simulator branch)
#       -> S: nothing reaches the screen (the readback alone would still pass)
#   M3  Attach leaves the layer framebufferOnly (Flutter turns it off so the
#       drawable stays readable) -> L: framebuffer_only=1 read back from the layer
# Then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-metal-ios-sim.sh
HOST=engine/ios/testhost/TestHostMetal.mm
SURF=engine/host/MetalSurfaceIOS.mm
mut_backup "$HOST" "$SURF"

mut_apply "$HOST" 'ImpellerDisplayListBuilderDrawRoundedRect(b, &rect, &radii, paint);' \
  'ImpellerDisplayListBuilderDrawRect(b, &rect, paint);  // MUTANT M1
  (void)radii;'
mut_expect M1 "$GATE" 'IOS_METAL_GATE FAIL R: .*corner_aa=0'

mut_apply "$SURF" '    ImpellerSurfacePresent(impl_->surface);
    if (onDisplayed) onDisplayed(0);' '    // MUTANT M2: no ImpellerSurfacePresent
    if (onDisplayed) onDisplayed(0);'
mut_expect M2 "$GATE" 'IOS_METAL_GATE FAIL S: '

mut_apply "$SURF" 'layer.framebufferOnly = NO;' 'layer.framebufferOnly = YES;  // MUTANT M3'
mut_expect M3 "$GATE" 'IOS_METAL_GATE FAIL L: layer: .*framebuffer_only=1'

mut_restore
mut_clean "$GATE" '^IOS_METAL_PASS '
mut_summary MUTATION_VERIFY_METAL_IOS_SIM
