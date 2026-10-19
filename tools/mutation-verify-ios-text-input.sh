#!/usr/bin/env bash
# Mutants for tools/ci-ios-text-input.sh (autocorrect + Japanese composition),
# run on linux with RNI_MAC_HOST set; each mutated tree is synced by the gate.
#   M1  setMarkedText never reaches the engine (the composition is dropped)
#       -> M: no marked text, no kana in JS
#   M2  replaceRange:withText: (how autocorrect lands) is dropped -> A
#   M3  the engine's replaceTextInputRange ignores the replacement text (only
#       the selection moves) -> A
#   M4  the field's keyboard traits are never applied, so autoCorrect={false}
#       is ignored and the keyboard corrects "teh " there too -> C
# Then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-ios-text-input.sh
TV=engine/ios/RNITextInputView.mm
FH=engine/fabric/FabricHostTextEdit.cpp
mut_backup "$TV" "$FH"

mut_apply "$TV" '  [self replace:r with:t selection:NSMakeRange(r.location + selLoc, selLen)];' \
  '  // MUTANT M1: the composition is dropped'
mut_expect M1 "$GATE" 'IOS_TEXT_INPUT_GATE FAIL M: '

mut_apply "$TV" '  const NSRange r = [self clamp:Rng(range)];
  [self replace:r with:text selection:NSMakeRange(r.location + text.length, 0)];' \
  '  const NSRange r = [self clamp:Rng(range)];  // MUTANT M2: replaceRange dropped'
mut_expect M2 "$GATE" 'IOS_TEXT_INPUT_GATE FAIL A: '

mut_apply "$FH" '  if (textChanged) value.replace(lo, hi - lo, text);' \
  '  // MUTANT M3: the replacement text is ignored'
mut_expect M3 "$GATE" 'IOS_TEXT_INPUT_GATE FAIL A: '

mut_apply "$TV" '  if (_fabric->textInputKeyboardTraits(&traits)) [self applyTraits:traits];' \
  '  // MUTANT M4: the keyboard traits are never applied'
mut_expect M4 "$GATE" 'IOS_TEXT_INPUT_GATE FAIL C: '

mut_restore
mut_clean "$GATE" '^IOS_TEXT_INPUT_PASS '
mut_summary MUTATION_VERIFY_IOS_TEXT_INPUT
