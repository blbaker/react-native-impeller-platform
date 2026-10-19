#!/usr/bin/env bash
# iOS Task 1.5 mutants for tools/ci-clipboard-ios.sh (run on linux):
#   M1  the UIPasteboard write is a no-op that still "succeeds"
#       -> O: the outside read shows the stale value
#   M2  the wake never schedules drainMain on the main queue, so queued
#       requests never run -> W
# Then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-clipboard-ios.sh
CLIP=engine/modules/ClipboardIOS.mm
mut_backup "$CLIP"

mut_apply "$CLIP" '        UIPasteboard.generalPasteboard.string = [NSString stringWithUTF8String:s.c_str()] ?: @"";' \
  '        (void)s;  // MUTANT M1: the write is dropped'
mut_expect M1 "$GATE" 'IOS_CLIPBOARD_GATE FAIL O: the OS pasteboard holds .stale-'

mut_apply "$CLIP" '      b->drainMain();' '      (void)b;  // MUTANT M2: never drained'
mut_expect M2 "$GATE" 'IOS_CLIPBOARD_GATE FAIL W: '

mut_restore
mut_clean "$GATE" '^IOS_CLIPBOARD_PASS '
mut_summary MUTATION_VERIFY_CLIPBOARD_IOS
