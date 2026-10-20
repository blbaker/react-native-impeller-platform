#!/usr/bin/env bash
# Mutants for tools/ci-ios-keyboard.sh (Keyboard events + KeyboardAvoidingView),
# run on linux with RNI_MAC_HOST set; each mutated tree is synced by the gate.
#   M1  the keyboard events never reach JS -> E
#   M2  endCoordinates carries the keyboard's START frame (for a show: off the
#       bottom of the screen), so KeyboardAvoidingView pads nothing -> A
#   M3  RNIEngine's frame loop no longer ticks LayoutAnimation: JS lays the
#       footer out above the keyboard, the screen never shows it there -> P
# Then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-ios-keyboard.sh
KB=engine/ios/RNIKeyboardEventsIOS.mm
ENG=engine/ios/RNIEngine.mm
mut_backup "$KB" "$ENG"

mut_apply "$KB" '  _sink->emit(name.UTF8String, payload);' '  // MUTANT M1: never emitted'
mut_expect M1 "$GATE" 'IOS_KEYBOARD_GATE FAIL E: '

mut_apply "$KB" '      "endCoordinates", Coordinates(end))' '      "endCoordinates", Coordinates(begin))  /* MUTANT M2 */'
mut_expect M2 "$GATE" 'IOS_KEYBOARD_GATE FAIL A: '

mut_apply "$ENG" '  s.session->fabricHost().tickLayoutAnimations();' \
  '  // MUTANT M3: LayoutAnimation is never ticked'
mut_expect M3 "$GATE" 'IOS_KEYBOARD_GATE FAIL P: '

mut_restore
mut_clean "$GATE" '^IOS_KEYBOARD_PASS '
mut_summary MUTATION_VERIFY_IOS_KEYBOARD
