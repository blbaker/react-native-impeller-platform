#pragma once

// The Android window surface: an ANativeWindow -> VkSurfaceKHR -> Impeller
// swapchain, and the third peer of HeadlessSurface / GlfwSurface.
//
// ⛔ WHY THIS IS VULKAN AND EVERY OTHER SURFACE IN THIS ENGINE IS GL.
//
// Impeller's Android story is Vulkan-first (GLES 2.0 only as a fallback for
// devices without it), and the SDK exposes exactly one windowed path per API:
//
//   desktop GL   ImpellerSurfaceCreateWrappedFBONew(fbo 0)
//   Android      ImpellerVulkanSwapchainCreateNew(VkSurfaceKHR)
//
// The SDK's own example_vk.c is the reference for the second, and the ONLY
// platform-specific step in it is how the VkSurfaceKHR is obtained --
// glfwCreateWindowSurface() there, vkCreateAndroidSurfaceKHR() here. The
// context creation, the acquire/draw/present loop and the display-list API are
// byte-for-byte the same calls, which is what makes the whole SceneGraph and
// SVG tier portable without a fork. (Verified: the android-arm64 SDK's
// include/impeller.h is md5-identical to the linux-x64 one.)
//
// ⛔ AND VULKAN IS LOADED AT RUNTIME, NOT LINKED.
//
// libvulkan.so exists on API 24+ but linking it outright makes the whole
// library fail to load on a device that lacks it, instead of failing on this
// one surface. Everything goes through dlopen + a proc-address callback, which
// is also exactly what ImpellerContextCreateVulkanNew asks for.

#include <android/native_window.h>
#include <cstdint>
#include <vector>

#include "impeller.h"

namespace rni {

class AndroidVkSurface {
 public:
  AndroidVkSurface() = default;
  ~AndroidVkSurface();

  AndroidVkSurface(const AndroidVkSurface&) = delete;
  AndroidVkSurface& operator=(const AndroidVkSurface&) = delete;

  // Binds to a live ANativeWindow. Retains the window for the surface's
  // lifetime. Returns false with a reason logged on any failure -- a device
  // without Vulkan is an expected outcome here, not an assert.
  bool Init(ANativeWindow* window);

  // Releases the swapchain and surface but keeps the Vulkan context, so a
  // surfaceDestroyed/surfaceCreated cycle (backgrounding, rotation) does not
  // pay for context recreation.
  void DetachWindow();
  bool AttachWindow(ANativeWindow* window);

  bool valid() const { return swapchain_ != nullptr; }
  ImpellerContext context() const { return context_; }
  int width() const { return width_; }
  int height() const { return height_; }

  // Acquires the next drawable. Returns nullptr when the swapchain is out of
  // date (the caller should re-attach); the returned surface is owned by the
  // caller and must be released after Present.
  ImpellerSurface AcquireNext();
  void Present(ImpellerSurface surface);

 private:
  bool EnsureContext();

  void* vulkan_lib_{nullptr};        // dlopen handle for libvulkan.so
  void* vk_instance_{nullptr};       // borrowed from Impeller, not owned
  void* vk_surface_khr_{nullptr};    // ownership transfers to the swapchain
  ANativeWindow* window_{nullptr};
  ImpellerContext context_{nullptr};
  ImpellerVulkanSwapchain swapchain_{nullptr};
  int width_{0};
  int height_{0};
};

}  // namespace rni
