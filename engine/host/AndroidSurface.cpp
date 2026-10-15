#include "host/AndroidSurface.h"

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>

#include <android/api-level.h>
#include <android/log.h>
#include <sys/system_properties.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>
#include <set>
#include <vector>

#include "host/AndroidDriverInfo.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "rn-impeller", __VA_ARGS__)

namespace rni {
namespace {

std::string Prop(const char* name) {
  char value[PROP_VALUE_MAX] = {};
  __system_property_get(name, value);
  return value;
}

bool EnvOn(const char* name) {
  const char* v = std::getenv(name);
  return v != nullptr && std::strcmp(v, "1") == 0;
}

android::DeviceProps ReadDeviceProps() {
  android::DeviceProps p;
  p.api_level = android_get_device_api_level();
  p.hardware = Prop("ro.hardware");
  p.model = Prop("ro.product.model");
  p.client_id_base = Prop("ro.com.google.clientidbase");
  p.board = Prop("ro.product.board");
  const std::string vendor_sdk = Prop("ro.vendor.build.version.sdk");
  if (!vendor_sdk.empty()) p.vendor_api_level = std::atoi(vendor_sdk.c_str());
  p.mediatek = __system_property_find("ro.vendor.mediatek.platform") != nullptr;
  p.qemu_pipe = ::access("/dev/qemu_pipe", F_OK) == 0;
  return p;
}

template <typename Fn>
Fn Proc(void* instance, const char* name) {
  return reinterpret_cast<Fn>(AndroidVkSurface::InstanceProc(instance, name));
}

std::set<std::string> Names(const std::vector<VkExtensionProperties>& exts) {
  std::set<std::string> out;
  for (const auto& e : exts) out.insert(e.extensionName);
  return out;
}

// capabilities_vk.cc: RequiredCommonDeviceExtensionVK + the Android set.
constexpr const char* kRequiredDeviceExtensions[] = {
    "VK_KHR_swapchain",
    "VK_ANDROID_external_memory_android_hardware_buffer",
    "VK_KHR_sampler_ycbcr_conversion",
    "VK_KHR_external_memory",
    "VK_EXT_queue_family_foreign",
    "VK_KHR_dedicated_allocation",
};

std::string VersionString(uint32_t v) {
  return std::to_string(VK_API_VERSION_MAJOR(v)) + "." +
         std::to_string(VK_API_VERSION_MINOR(v)) + "." +
         std::to_string(VK_API_VERSION_PATCH(v));
}

}  // namespace

bool AndroidSurface::TryVulkan() {
  if (const char* r = android::PlatformDenyReason(ReadDeviceProps())) {
    reason_ = r;
    return false;
  }
  vk_ = std::make_unique<AndroidVkSurface>();
  if (!vk_->LoadLoader()) { reason_ = "no_libvulkan"; return false; }
  uint32_t loader = VK_API_VERSION_1_0;
  if (auto enum_version = Proc<PFN_vkEnumerateInstanceVersion>(
          nullptr, "vkEnumerateInstanceVersion")) {
    enum_version(&loader);
  }
  if (loader < VK_API_VERSION_1_1) { reason_ = "vulkan_loader<1.1"; return false; }
  auto enum_inst = Proc<PFN_vkEnumerateInstanceExtensionProperties>(
      nullptr, "vkEnumerateInstanceExtensionProperties");
  uint32_t n = 0;
  if (enum_inst == nullptr || enum_inst(nullptr, &n, nullptr) != VK_SUCCESS) {
    reason_ = "no_instance_extensions";
    return false;
  }
  std::vector<VkExtensionProperties> inst(n);
  enum_inst(nullptr, &n, inst.data());
  const auto inst_names = Names(inst);
  for (const char* e : {"VK_KHR_surface", "VK_KHR_android_surface"}) {
    if (!inst_names.count(e)) { reason_ = std::string("missing_") + e; return false; }
  }

  vk_->set_force_init_failure(forced_init_fail_);
  if (!vk_->CreateContext()) { reason_ = "vulkan_init_failed"; return false; }

  ImpellerContextVulkanInfo info = {};
  if (!ImpellerContextGetVulkanInfo(vk_->context(), &info)) {
    reason_ = "no_vulkan_info";
    return false;
  }
  auto get_props = Proc<PFN_vkGetPhysicalDeviceProperties>(
      info.vk_instance, "vkGetPhysicalDeviceProperties");
  auto enum_dev = Proc<PFN_vkEnumerateDeviceExtensionProperties>(
      info.vk_instance, "vkEnumerateDeviceExtensionProperties");
  if (get_props == nullptr || enum_dev == nullptr) { reason_ = "no_device_query"; return false; }
  auto* gpu = static_cast<VkPhysicalDevice>(info.vk_physical_device);
  VkPhysicalDeviceProperties props = {};
  get_props(gpu, &props);
  android::VkDriverIdentity id;
  id.vendor_id = props.vendorID;
  id.device_id = props.deviceID;
  id.driver_version = props.driverVersion;
  id.api_version = props.apiVersion;
  id.device_type = props.deviceType;
  id.device_name = props.deviceName;
  gpu_ = id.device_name;
  vk_api_ = VersionString(id.api_version);
  if (id.api_version < VK_API_VERSION_1_1) { reason_ = "device_vulkan<1.1"; return false; }
  n = 0;
  enum_dev(gpu, nullptr, &n, nullptr);
  std::vector<VkExtensionProperties> dev(n);
  enum_dev(gpu, nullptr, &n, dev.data());
  const auto dev_names = Names(dev);
  for (const char* e : kRequiredDeviceExtensions) {
    if (!dev_names.count(e)) { reason_ = std::string("missing_") + e; return false; }
  }

  // Test hook: run the REAL deny list on a known-bad identity.
  if (forced_bad_driver_) id = android::ForcedBadDriverIdentity();
  if (const char* r = android::KnownBadDriverReason(id)) {
    reason_ = std::string("known_bad_driver:") + r;
    return false;
  }
  reason_ = "ok";
  return true;
}

bool AndroidSurface::Select(ANativeWindow* window) {
  forced_bad_driver_ = EnvOn("RNI_FORCE_BAD_DRIVER");
  forced_init_fail_ = EnvOn("RNI_FORCE_VULKAN_INIT_FAIL");
  if (TryVulkan()) {
    if (vk_->AttachWindow(window)) {
      backend_ = Backend::kVulkan;
      LogDecision();
      return true;
    }
    reason_ = "vulkan_swapchain_failed";
  }
  // Flutter drops the rejected Vulkan context before creating GLES.
  vk_.reset();
  gl_ = std::make_unique<AndroidGlSurface>();
  if (gl_->Init(window)) {
    backend_ = Backend::kGles;
  } else {
    gl_.reset();
    reason_ += ",gles_init_failed";
  }
  LogDecision();
  return backend_ != Backend::kNone;
}

void AndroidSurface::LogDecision() const {
  LOGI("android_backend=%s reason=%s gpu=\"%s\" vk_api=%s gles=%d samples=%d "
       "api_level=%d forced_bad_driver=%d forced_init_fail=%d",
       backend_name(), reason_.c_str(), gpu_.c_str(),
       vk_api_.empty() ? "-" : vk_api_.c_str(), gl_ ? gl_->gl_major() : 0,
       gl_ ? gl_->samples() : 0, android_get_device_api_level(),
       forced_bad_driver_ ? 1 : 0, forced_init_fail_ ? 1 : 0);
}

const char* AndroidSurface::backend_name() const {
  switch (backend_) {
    case Backend::kVulkan: return "vulkan";
    case Backend::kGles: return "gles";
    case Backend::kNone: break;
  }
  return "none";
}

bool AndroidSurface::Init(ANativeWindow* window) {
  if (window == nullptr) return false;
  if (backend_ == Backend::kNone) return Select(window);
  return AttachWindow(window);
}

void AndroidSurface::DetachWindow() {
  if (vk_) vk_->DetachWindow();
  if (gl_) gl_->DetachWindow();
}

bool AndroidSurface::AttachWindow(ANativeWindow* window) {
  if (backend_ == Backend::kVulkan) return vk_->AttachWindow(window);
  if (backend_ == Backend::kGles) return gl_->AttachWindow(window);
  return Init(window);
}

bool AndroidSurface::valid() const {
  if (backend_ == Backend::kVulkan) return vk_->valid();
  if (backend_ == Backend::kGles) return gl_->valid();
  return false;
}

ImpellerContext AndroidSurface::context() const {
  if (backend_ == Backend::kVulkan) return vk_->context();
  if (backend_ == Backend::kGles) return gl_->context();
  return nullptr;
}

int AndroidSurface::width() const {
  if (backend_ == Backend::kVulkan) return vk_->width();
  return backend_ == Backend::kGles ? gl_->width() : 0;
}

int AndroidSurface::height() const {
  if (backend_ == Backend::kVulkan) return vk_->height();
  return backend_ == Backend::kGles ? gl_->height() : 0;
}

ImpellerSurface AndroidSurface::AcquireNext() {
  if (backend_ == Backend::kVulkan) return vk_->AcquireNext();
  return backend_ == Backend::kGles ? gl_->AcquireNext() : nullptr;
}

void AndroidSurface::Present(ImpellerSurface surface) {
  if (backend_ == Backend::kVulkan) vk_->Present(surface);
  if (backend_ == Backend::kGles) gl_->Present(surface);
}

}  // namespace rni
