#!/usr/bin/env bash
# Mutants for tools/ci-ios-device-build.sh, run on linux with RNI_MAC_HOST set;
# each mutated tree (or setting) is synced/forwarded by the gate.
#   M1  the Simulator Impeller SDK linked into the device app
#       (RNI_IOS_SDK) -> B: the linker refuses a Simulator object
#   M2  the Simulator engine library linked into the device app
#       (RNI_IOS_ENGINE_LIB) -> B
#   M3  the device app keeps the test host's iPhoneSimulator Info.plist -> P
# The R arm (one C++ exception runtime, one jsi) needs a rebuilt SDK or engine
# to break; its mutants live with the simulator gates (ci-ios-raf.sh M3) and
# the probe in tools/impeller-sdk-ios-build.sh's comment.
# Then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-ios-device-build.sh
LIB=tools/lib/ios-sim.sh
mut_backup "$LIB"

export RNI_IOS_SDK=engine/third_party/impeller-sdk-ios-simulator-arm64
mut_expect M1 "$GATE" 'IOS_DEVICE_BUILD_FAIL \(B: test host link\)'
unset RNI_IOS_SDK

export RNI_IOS_ENGINE_LIB=engine/build-ios-simulator/librni_ios_all.a
mut_expect M2 "$GATE" 'IOS_DEVICE_BUILD_FAIL \(B: test host link\)'
unset RNI_IOS_ENGINE_LIB

mut_apply "$LIB" "    plutil -replace CFBundleSupportedPlatforms -json '[\"iPhoneOS\"]' \"\$IOS_APP/Info.plist\"" \
  '    : # MUTANT M3: Info.plist keeps iPhoneSimulator'
mut_expect M3 "$GATE" 'IOS_DEVICE_BUILD_GATE FAIL P: Info.plist'

mut_restore
mut_clean "$GATE" '^IOS_DEVICE_BUILD_PASS '
mut_summary MUTATION_VERIFY_IOS_DEVICE_BUILD
