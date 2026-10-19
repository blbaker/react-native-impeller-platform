// iOS Phase 1 / Task 1.3: the UIKit lifecycle drives the one GPU-availability
// switch (engine/base/GpuAvailability.h, FP-31), unchanged.
//
// Model: flutter/shell/platform/darwin/ios/framework/Source/FlutterEngine.mm,
// which on UIApplicationDidEnterBackgroundNotification calls
// setIsGpuDisabled:YES (Shell::SetGpuAvailability -> the sync switch every
// raster draw/present and IO upload checks) and on
// UIApplicationWillEnterForegroundNotification setIsGpuDisabled:NO. iOS may
// kill an app that submits GPU work in the background (research doc
// 03-embedding-platform.md section 3), which is why the flip waits for GPU work
// already in flight: rni::gpu::Set takes the switch exclusive.
#pragma once

namespace rni::gpu {

// Main thread. Registers for the two notifications: background ->
// Set(false, "ios_background"), foreground -> Set(true, "ios_foreground").
// Idempotent. If the app is already in the background, flips to unavailable
// now. Set(false) blocks until GPU sections in flight finish (at most the
// frame in progress); iOS gives the handler seconds, a frame takes ms.
void InstallGpuAvailabilityObservers();
// Main thread. Unregisters (engine shutdown, tests). Leaves the switch as is.
void RemoveGpuAvailabilityObservers();

}  // namespace rni::gpu
