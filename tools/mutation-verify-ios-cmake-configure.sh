#!/usr/bin/env bash
# iOS Task 1.6 mutants for tools/ci-ios-cmake-configure.sh (run on linux with
# RNI_MAC_HOST set). These mutate the Mac copy's STAGED inputs, not the source: each one
# moves a dependency away from its expected path, and configure must fail with
# that dependency's own named error (not a generic downstream one).
#   M1  the iOS Hermes xcframework is missing
#       -> C: "iOS Hermes xcframework not found"
#   M2  the iOS Simulator Impeller SDK is missing
#       -> C: "iOS Impeller SDK (simulator-arm64) not found"
# The moved dirs are put back on exit, then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-ios-cmake-configure.sh
MAC="${RNI_MAC_HOST:?RNI_MAC_HOST=<ssh host of a Mac> is required}"
T="${RNI_MAC_TREE:-rni-ios}/engine/third_party"
# ⛔ Park OUTSIDE the Mac copy: the gate's own sync (rsync --delete) removes
# anything in the tree its protect rules do not name (a `.hermes-ios.mutant`
# parked beside the original was deleted, losing both staged inputs).
PARK="Library/Caches/rni-ios-ci/mutant-park"
mac() { ssh -o BatchMode=yes "$MAC" "$@"; }
hide() { mac "mkdir -p ~/$PARK && rm -rf ~/$PARK/$1 && cd ~/$T && test -d $1 && mv $1 ~/$PARK/$1"; }
unhide() { mac "if [ -d ~/$PARK/$1 ]; then rm -rf ~/$T/$1 && mv ~/$PARK/$1 ~/$T/$1; fi"; }
trap 'unhide hermes-ios; unhide impeller-sdk-ios-simulator-arm64; mut_restore; rm -rf "$MUT_BACKUP"' EXIT

hide hermes-ios || { echo "no staged hermes-ios on the Mac (run tools/hermes-build-ios.sh)"; exit 1; }
mut_expect M1 "$GATE" 'IOS_CMAKE_GATE FAIL C: .*iOS Hermes xcframework not found'
unhide hermes-ios

hide impeller-sdk-ios-simulator-arm64 || { echo "no staged iOS SDK on the Mac (run tools/sdk-fetch-ios.sh)"; exit 1; }
mut_expect M2 "$GATE" 'IOS_CMAKE_GATE FAIL C: .*iOS Impeller SDK \(simulator-arm64\) not found'
unhide impeller-sdk-ios-simulator-arm64

mut_clean "$GATE" '^IOS_CMAKE_CONFIGURE_PASS '
mut_summary MUTATION_VERIFY_IOS_CMAKE_CONFIGURE
