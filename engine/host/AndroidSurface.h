#pragma once

// FP-25: the Android window surface the host uses, Vulkan or GLES, chosen once
// per process-lifetime surface object. Model:
// shell/platform/android/android_surface_dynamic_impeller.cc (forward every
// call to whichever surface the context picked) and
// android_context_dynamic_impeller.cc SetupImpellerContext (try Vulkan, fall
// back to GLES). Selection, in order (first hit picks GLES):
//   1. PlatformDenyReason: API < 29, emulator, Huawei, MediaTek < 32, bad SoC
//   2. no libvulkan.so, loader < Vulkan 1.1, no VK_KHR_surface /
//      VK_KHR_android_surface
//   3. ImpellerContextCreateVulkanNew fails (RNI_FORCE_VULKAN_INIT_FAIL=1
//      forces it: Impeller's vkCreateInstance fails)
//   4. the context's physical device: Vulkan < 1.1, a required device
//      extension missing, or KnownBadDriverReason (DriverInfoVK::
//      IsKnownBadDriver; RNI_FORCE_BAD_DRIVER=1 substitutes an Adreno 650)
//   5. the first Vulkan swapchain cannot be created on the window
// One log line, tag rn-impeller:
//   android_backend=vulkan|gles|none reason=... gpu="..." ...

#include <android/native_window.h>

#include <memory>
#include <string>

#include "host/AndroidGlSurface.h"
#include "host/AndroidVkSurface.h"

namespace rni {

class AndroidSurface {
 public:
  enum class Backend { kNone, kVulkan, kGles };

  // The first call selects the backend; later calls reattach.
  bool Init(ANativeWindow* window);
  void DetachWindow();
  bool AttachWindow(ANativeWindow* window);

  bool valid() const;
  ImpellerContext context() const;
  int width() const;
  int height() const;
  ImpellerSurface AcquireNext();
  void Present(ImpellerSurface surface);

  Backend backend() const { return backend_; }
  const char* backend_name() const;
  const std::string& reason() const { return reason_; }
  AndroidVkSurface* vk() { return vk_.get(); }
  AndroidGlSurface* gl() { return gl_.get(); }

 private:
  // Steps 1-4; on success vk_ holds a live context, else reason_ is set.
  bool TryVulkan();
  bool Select(ANativeWindow* window);
  void LogDecision() const;

  Backend backend_{Backend::kNone};
  std::string reason_;
  std::string gpu_;     // VkPhysicalDeviceProperties::deviceName, if read
  std::string vk_api_;  // device apiVersion "M.m.p", if read
  bool forced_bad_driver_{false};
  bool forced_init_fail_{false};
  std::unique_ptr<AndroidVkSurface> vk_;
  std::unique_ptr<AndroidGlSurface> gl_;
};

}  // namespace rni
