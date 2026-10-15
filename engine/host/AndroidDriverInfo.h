#pragma once

// FP-25: the pure half of Android backend selection (no Android or Vulkan
// headers, so a host unit test can table-test every deny-list entry).
// Models two Flutter files at our SDK pin:
//   shell/platform/android/android_context_dynamic_impeller.cc
//     GetActualRenderingAPIForImpeller: emulator, Huawei, MediaTek < 32,
//     kBadSocs (checked before any Vulkan context exists)
//   impeller/renderer/backend/vulkan/driver_info_vk.cc L377-L409
//     DriverInfoVK::IsKnownBadDriver (checked on the created context's
//     physical device; android_context_vk_impeller.cc L65 drops the context)
// Each function returns nullptr when Vulkan is allowed, else a short reason
// token for the `android_backend=gles reason=...` log line.

#include <cstdint>
#include <string>

namespace rni::android {

// System properties read by Flutter's selector (empty string = unset).
struct DeviceProps {
  int api_level = 0;
  std::string hardware;        // ro.hardware
  std::string model;           // ro.product.model
  std::string client_id_base;  // ro.com.google.clientidbase
  std::string board;           // ro.product.board
  int vendor_api_level = -1;   // ro.vendor.build.version.sdk, -1 = unset
  bool mediatek = false;       // ro.vendor.mediatek.platform exists
  bool qemu_pipe = false;      // /dev/qemu_pipe exists
};

// VkPhysicalDeviceProperties fields DriverInfoVK reads.
struct VkDriverIdentity {
  uint32_t vendor_id = 0;
  uint32_t device_id = 0;
  uint32_t driver_version = 0;
  uint32_t api_version = 0;  // VK_MAKE_API_VERSION packing
  int device_type = 0;       // VkPhysicalDeviceType
  std::string device_name;
};

// flutter_main.cc kMinimumAndroidApiLevelForImpeller; below it Flutter drops
// Impeller entirely, we keep Impeller on GLES.
constexpr int kMinApiLevelForVulkan = 29;

const char* PlatformDenyReason(const DeviceProps& props);
const char* KnownBadDriverReason(const VkDriverIdentity& id);

// The identity RNI_FORCE_BAD_DRIVER=1 substitutes for the real one: an
// Adreno 650 (flutter#178285), so the forced path runs the real deny list.
VkDriverIdentity ForcedBadDriverIdentity();

}  // namespace rni::android
