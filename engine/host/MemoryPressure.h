#pragma once

// FP-33: OS low-memory signals -> rni::image::HandleLowMemory (Flutter: the embedders'
// didHaveMemoryPressure: iOS didReceiveMemoryWarning, Android onTrimMemory).
//   macOS    DISPATCH_SOURCE_TYPE_MEMORYPRESSURE (warn | critical)
//   Windows  CreateMemoryResourceNotification(LowMemoryResourceNotification)
//   Android  ImpellerRenderer.onTrimMemory -> rni_handle_low_memory (fabric/ImageBudget.cpp)
//   Linux    PSI trigger on /proc/pressure/memory, default "some 100000 2000000" (100 ms stalled in
//            any 2 s window); RNI_MEM_PSI=off disables it, RNI_MEM_PSI="some|full <us> <us>" replaces
//            it. Logs one memory_pressure line at start (armed=1, or armed=0 with the reason) and one
//            per kernel event (stall_us since the last purge, action=purge|skip). If opening the
//            trigger fails with EPERM (no CAP_SYS_RESOURCE, kernels before 6.5) it samples the same
//            file every 2 s instead (source=psi-poll; same threshold, same purge, one line per purge).
//            RNI_MEM_PSI=off turns off both. Gate: tools/ci-mem-psi.sh
//   RNI_TEST_LOW_MEMORY_AT_FRAME is the test hook on every platform
namespace rni::memorypressure {
void Start();
}
