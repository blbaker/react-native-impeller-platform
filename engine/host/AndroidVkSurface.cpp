#include "host/AndroidVkSurface.h"

#include "base/ContextFlags.h"

#include <android/log.h>
#include <dlfcn.h>

#include <cstring>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "rn-impeller", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "rn-impeller", __VA_ARGS__)

namespace rni {
namespace {

// Minimal Vulkan declarations. The NDK ships <vulkan/vulkan.h>, but pulling it
// in drags the whole API surface into a file that needs exactly three symbols,
// and every one of them is resolved by dlsym anyway.
using VkInstance = void*;
using VkSurfaceKHR_T = uint64_t;
using PFN_vkVoidFunction = void (*)(void);
using PFN_vkGetInstanceProcAddr = PFN_vkVoidFunction (*)(VkInstance,
                                                         const char*);

struct VkAndroidSurfaceCreateInfoKHR {
  int32_t sType;
  const void* pNext;
  uint32_t flags;
  ANativeWindow* window;
};

// VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR
constexpr int32_t kAndroidSurfaceCreateInfoType = 1000008000;

using PFN_vkCreateAndroidSurfaceKHR =
    int32_t (*)(VkInstance, const VkAndroidSurfaceCreateInfoKHR*, const void*,
                VkSurfaceKHR_T*);

PFN_vkGetInstanceProcAddr g_get_instance_proc_addr = nullptr;

// The callback Impeller uses to resolve every Vulkan entry point it needs.
// ⛔ Its signature takes the instance as void*; passing our dlsym'd
// vkGetInstanceProcAddr straight through is the whole contract.
void* ImpellerVkProcAddress(void* vk_instance, const char* name,
                            void* /*user_data*/) {
  if (g_get_instance_proc_addr == nullptr) return nullptr;
  return reinterpret_cast<void*>(
      g_get_instance_proc_addr(vk_instance, name));
}

}  // namespace

AndroidVkSurface::~AndroidVkSurface() {
  DetachWindow();
  if (context_ != nullptr) {
    ImpellerContextRelease(context_);
    context_ = nullptr;
  }
  if (vulkan_lib_ != nullptr) {
    dlclose(vulkan_lib_);
    vulkan_lib_ = nullptr;
  }
}

bool AndroidVkSurface::EnsureContext() {
  if (context_ != nullptr) return true;

  // ⛔ dlopen, NOT a link-time dependency. Linking libvulkan.so would make the
  // ENTIRE library fail to load on a device without it -- including the parts
  // that have nothing to do with rendering -- instead of failing here where a
  // caller can fall back.
  if (vulkan_lib_ == nullptr) {
    vulkan_lib_ = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (vulkan_lib_ == nullptr) {
      LOGE("libvulkan.so not present: %s", dlerror());
      return false;
    }
  }

  g_get_instance_proc_addr =
      reinterpret_cast<PFN_vkGetInstanceProcAddr>(
          dlsym(vulkan_lib_, "vkGetInstanceProcAddr"));
  if (g_get_instance_proc_addr == nullptr) {
    LOGE("vkGetInstanceProcAddr missing from libvulkan.so");
    return false;
  }

  ImpellerContextVulkanSettings settings = {};
  settings.user_data = nullptr;
  settings.proc_address_callback = ImpellerVkProcAddress;
  settings.enable_vulkan_validation = false;

  rni::contextflags::ApplyBeforeCreate();  // FP-22
  context_ = ImpellerContextCreateVulkanNew(IMPELLER_VERSION, &settings);
  rni::contextflags::Report(context_);
  if (context_ == nullptr) {
    LOGE("ImpellerContextCreateVulkanNew failed (no Vulkan 1.1 device?)");
    return false;
  }
  LOGI("Impeller Vulkan context created");
  return true;
}

bool AndroidVkSurface::Init(ANativeWindow* window) {
  if (!EnsureContext()) return false;
  return AttachWindow(window);
}

bool AndroidVkSurface::AttachWindow(ANativeWindow* window) {
  if (window == nullptr) return false;
  if (!EnsureContext()) return false;

  DetachWindow();

  ANativeWindow_acquire(window);
  window_ = window;
  width_ = ANativeWindow_getWidth(window);
  height_ = ANativeWindow_getHeight(window);

  if (!CreateSwapchain()) {
    DetachWindow();
    return false;
  }
  LOGI("Android Vulkan swapchain ready: %dx%d", width_, height_);
  return true;
}

bool AndroidVkSurface::CreateSwapchain() {
  ImpellerContextVulkanInfo info = {};
  if (!ImpellerContextGetVulkanInfo(context_, &info)) {
    LOGE("ImpellerContextGetVulkanInfo failed");
    return false;
  }
  vk_instance_ = info.vk_instance;

  auto create_surface = reinterpret_cast<PFN_vkCreateAndroidSurfaceKHR>(
      g_get_instance_proc_addr(vk_instance_, "vkCreateAndroidSurfaceKHR"));
  if (create_surface == nullptr) {
    LOGE("vkCreateAndroidSurfaceKHR unavailable (VK_KHR_android_surface "
         "missing)");
    return false;
  }

  VkAndroidSurfaceCreateInfoKHR ci = {};
  ci.sType = kAndroidSurfaceCreateInfoType;
  ci.pNext = nullptr;
  ci.flags = 0;
  ci.window = window_;

  VkSurfaceKHR_T surface = 0;
  const int32_t err = create_surface(vk_instance_, &ci, nullptr, &surface);
  if (err != 0 || surface == 0) {
    LOGE("vkCreateAndroidSurfaceKHR failed: %d", err);
    return false;
  }

  // ⛔ OWNERSHIP OF THE SURFACE TRANSFERS TO IMPELLER, per the header:
  // "Ownership of the surface is transferred over to Impeller." Destroying it
  // here as well is a double free. It is only tracked so a FAILED swapchain
  // creation can be reported accurately.
  vk_surface_khr_ = reinterpret_cast<void*>(static_cast<uintptr_t>(surface));

  swapchain_ = ImpellerVulkanSwapchainCreateNew(context_, vk_surface_khr_);
  if (swapchain_ == nullptr) {
    LOGE("ImpellerVulkanSwapchainCreateNew failed");
    vk_surface_khr_ = nullptr;
    return false;
  }
  // The interop swapchain starts at 1x1; the first SyncSize sizes it.
  swapchain_width_ = 0;
  swapchain_height_ = 0;
  return true;
}

void AndroidVkSurface::ReleaseSwapchain() {
  if (swapchain_ != nullptr) {
    ImpellerVulkanSwapchainRelease(swapchain_);
    swapchain_ = nullptr;
  }
  // The VkSurfaceKHR is owned by the swapchain; releasing the swapchain
  // released it. Only drop our record of it.
  vk_surface_khr_ = nullptr;
}

void AndroidVkSurface::DetachWindow() {
  ReleaseSwapchain();
  if (window_ != nullptr) {
    ANativeWindow_release(window_);
    window_ = nullptr;
  }
  width_ = 0;
  height_ = 0;
  swapchain_width_ = 0;
  swapchain_height_ = 0;
}

// Flutter: AndroidSurfaceVKImpeller::OnScreenSurfaceResize pushes the
// ANativeWindow size with SwapchainVK::UpdateSurfaceSize, because on Android
// KHRSwapchainVK never reads the surface extent itself (khr_swapchain_vk.cc,
// the !FML_OS_ANDROID block). We have no resize callback in this layer, so the
// window is polled once per acquire (two cheap ANativeWindow queries).
void AndroidVkSurface::SyncSize() {
  const int w = ANativeWindow_getWidth(window_);
  const int h = ANativeWindow_getHeight(window_);
  if (w <= 0 || h <= 0) return;
  width_ = w;
  height_ = h;
  if (w == swapchain_width_ && h == swapchain_height_) return;
#ifdef IMPELLER_RNI_VK_SWAPCHAIN_SIZE
  const ImpellerISize size = {w, h};
  ImpellerVulkanSwapchainSetSize(swapchain_, &size);
#else
  LOGE("stock Impeller SDK: no ImpellerVulkanSwapchainSetSize (patch 0004), "
       "the swapchain keeps its creation size");
#endif
  if (swapchain_width_ != 0) stats_.resizes++;
  LOGI("swapchain_resize %dx%d -> %dx%d", swapchain_width_, swapchain_height_,
       w, h);
  swapchain_width_ = w;
  swapchain_height_ = h;
}

ImpellerSurface AndroidVkSurface::AcquireNext() {
  if (swapchain_ == nullptr || window_ == nullptr) return nullptr;
  for (int attempt = 0;; ++attempt) {
    SyncSize();
    ImpellerSurface surface =
        ImpellerVulkanSwapchainAcquireNextSurfaceNew(swapchain_);
    if (surface != nullptr) {
#ifdef IMPELLER_RNI_VK_SWAPCHAIN_SIZE
      ImpellerISize drawn = {};
      if (ImpellerSurfaceGetSize(surface, &drawn)) {
        stats_.drawable_width = static_cast<int>(drawn.width);
        stats_.drawable_height = static_cast<int>(drawn.height);
      }
#endif
      return surface;
    }
    // Impeller recreates on OUT_OF_DATE / SUBOPTIMAL itself; a null drawable
    // means that recreate failed and its impl is gone (khr_swapchain_vk.cc
    // "This is unrecoverable"). Rebuild from the window, bounded like
    // kMaxResizeAttempts so a dead window cannot spin the frame loop.
    if (attempt == kMaxRecreateAttempts) {
      stats_.acquire_failures++;
      LOGE("swapchain acquire failed after %d recreates", attempt);
      return nullptr;
    }
    ReleaseSwapchain();
    if (!CreateSwapchain()) {
      stats_.acquire_failures++;
      return nullptr;
    }
    stats_.recreates++;
    LOGI("swapchain_recreate attempt=%d", attempt + 1);
  }
}

void AndroidVkSurface::Present(ImpellerSurface surface) {
  if (surface == nullptr) return;
  ImpellerSurfacePresent(surface);
  ImpellerSurfaceRelease(surface);
}

}  // namespace rni
