#!/usr/bin/env bash
# iOS Phase 4 spike mutants for tools/ci-ios-input.sh (real UIKit input), run on
# linux with RNI_MAC_HOST set; each mutated tree is synced by the gate.
#   M1  RNIEngine never installs its touch recognizer -> T: no touch_down
#   M2  a press that focuses a TextInput never makes the keyboard proxy first
#       responder (no system keyboard) -> K: keyboard never shown
#   M3  the keyboard proxy drops insertText -> I: JS value is none
# Then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-ios-input.sh
IN=engine/ios/RNIInputIOS.mm
mut_backup "$IN"

mut_apply "$IN" '  [view addGestureRecognizer:_touch];' '  // MUTANT M1: no touch recognizer'
mut_expect M1 "$GATE" 'IOS_INPUT_GATE FAIL T: no touch_down'

mut_apply "$IN" '  if (focused != 0 && !kb.isFirstResponder) [kb becomeFirstResponder];' \
  '  // MUTANT M2: the keyboard proxy never becomes first responder'
mut_expect M2 "$GATE" 'IOS_INPUT_GATE FAIL K: UIKit never reported the keyboard shown'

mut_apply "$IN" '- (void)insertText:(NSString*)text {
  if (!_fabric) return;' '- (void)insertText:(NSString*)text {
  return;  // MUTANT M3'
mut_expect M3 "$GATE" 'IOS_INPUT_GATE FAIL I: JS value is none'

mut_restore
mut_clean "$GATE" '^IOS_INPUT_PASS '
mut_summary MUTATION_VERIFY_IOS_INPUT
