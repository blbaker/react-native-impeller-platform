#!/usr/bin/env bash
# iOS Task 1.3 mutants for tools/ci-gpu-availability-ios.sh (run on linux):
#   M1  the host never calls InstallGpuAvailabilityObservers()
#       -> Z: presents during the background are nonzero
#   M2  the background observer turns the GPU ON, not off -> Z
#   M3  the foreground observer does nothing -> R: presents never resume
# Then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-gpu-availability-ios.sh
HOST=engine/ios/testhost/TestHostLifecycle.mm
OBS=engine/host/GpuAvailabilityIOS.mm
mut_backup "$HOST" "$OBS"

mut_apply "$HOST" '  rni::gpu::InstallGpuAvailabilityObservers();
  TestLog("gpu observers_installed=1");' '  // MUTANT M1: the installer is never called
  TestLog("gpu observers_installed=0");'
mut_expect M1 "$GATE" 'IOS_GPU_AVAILABILITY_GATE FAIL Z: GPU work in the background: presents=[1-9]'

mut_apply "$OBS" 'Set(false, "ios_background");' 'Set(true, "ios_background");  // MUTANT M2'
mut_expect M2 "$GATE" 'IOS_GPU_AVAILABILITY_GATE FAIL Z: GPU work in the background: presents=[1-9]'

mut_apply "$OBS" 'Set(true, "ios_foreground");' '(void)0;  // MUTANT M3'
mut_expect M3 "$GATE" 'IOS_GPU_AVAILABILITY_GATE FAIL R: '

mut_restore
mut_clean "$GATE" '^IOS_GPU_AVAILABILITY_PASS '
mut_summary MUTATION_VERIFY_GPU_AVAILABILITY_IOS
