#!/usr/bin/env bash
# Mutants for tools/ci-ios-blur-scroll.sh (expo-blur BlurView over moving
# content, iOS simulator), run on linux with RNI_MAC_HOST set; each mutated
# tree is synced by the gate.
#   M1  the BlurView paints no blur: the header shows the tiles sharp. They still
#       move under it and match the reference (M and S hold), so only B can
#       catch it -> B (header not blurred)
# The readback/partial-repaint mutants live with the desktop gate
# (tools/mutation-verify-blur-scroll.sh): RNIEngine repaints every frame in
# full, so they cannot fail on iOS.
# Then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-ios-blur-scroll.sh
SG=engine/scenegraph/SceneGraph.cpp
mut_backup "$SG"
mut_apply "$SG" '    rni::PaintBackdropBlur(builder, rect, node.blurTint, node.blurIntensity);' \
  '    // MUTANT M1: the BlurView paints no blur'
mut_expect M1 "$GATE" 'IOS_BLUR_SCROLL FAIL B: the header over the tiles is not blurred'
mut_restore
mut_clean "$GATE" '^IOS_BLUR_SCROLL_PASS '
mut_summary MUTATION_VERIFY_IOS_BLUR_SCROLL
