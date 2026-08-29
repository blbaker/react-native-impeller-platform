#include "host/AndroidVkSurface.h"

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

  context_ = ImpellerContextCreateVulkanNew(IMPELLER_VERSION, &settings);
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

  ImpellerContextVulkanInfo info = {};
  if (!ImpellerContextGetVulkanInfo(context_, &info)) {
    LOGE("ImpellerContextGetVulkanInfo failed");
    DetachWindow();
    return false;
  }
  vk_instance_ = info.vk_instance;

  auto create_surface = reinterpret_cast<PFN_vkCreateAndroidSurfaceKHR>(
      g_get_instance_proc_addr(vk_instance_, "vkCreateAndroidSurfaceKHR"));
  if (create_surface == nullptr) {
    LOGE("vkCreateAndroidSurfaceKHR unavailable (VK_KHR_android_surface "
         "missing)");
    DetachWindow();
    return false;
  }

  VkAndroidSurfaceCreateInfoKHR ci = {};
  ci.sType = kAndroidSurfaceCreateInfoType;
  ci.pNext = nullptr;
  ci.flags = 0;
  ci.window = window;

  VkSurfaceKHR_T surface = 0;
  const int32_t err = create_surface(vk_instance_, &ci, nullptr, &surface);
  if (err != 0 || surface == 0) {
    LOGE("vkCreateAndroidSurfaceKHR failed: %d", err);
    DetachWindow();
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
    DetachWindow();
    return false;
  }

  LOGI("Android Vulkan swapchain ready: %dx%d", width_, height_);
  return true;
}

void AndroidVkSurface::DetachWindow() {
  if (swapchain_ != nullptr) {
    ImpellerVulkanSwapchainRelease(swapchain_);
    swapchain_ = nullptr;
  }
  // The VkSurfaceKHR is owned by the swapchain; releasing the swapchain
  // released it. Only drop our record of it.
  vk_surface_khr_ = nullptr;
  if (window_ != nullptr) {
    ANativeWindow_release(window_);
    window_ = nullptr;
  }
  width_ = 0;
  height_ = 0;
}

ImpellerSurface AndroidVkSurface::AcquireNext() {
  if (swapchain_ == nullptr) return nullptr;
  return ImpellerVulkanSwapchainAcquireNextSurfaceNew(swapchain_);
}

void AndroidVkSurface::Present(ImpellerSurface surface) {
  if (surface == nullptr) return;
  ImpellerSurfacePresent(surface);
  ImpellerSurfaceRelease(surface);
}

}  // namespace rni
