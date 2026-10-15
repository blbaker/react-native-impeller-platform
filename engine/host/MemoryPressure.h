#pragma once

// FP-33: OS low-memory signals -> rni::image::HandleLowMemory (Flutter: the embedders'
// didHaveMemoryPressure: iOS didReceiveMemoryWarning, Android onTrimMemory).
//   macOS    DISPATCH_SOURCE_TYPE_MEMORYPRESSURE (warn | critical)
//   Windows  CreateMemoryResourceNotification(LowMemoryResourceNotification)
//   Android  ImpellerRenderer.onTrimMemory -> rni_handle_low_memory (fabric/ImageBudget.cpp)
//   Linux    none; RNI_TEST_LOW_MEMORY_AT_FRAME is the test hook on every platform
namespace rni::memorypressure {
void Start();
}
