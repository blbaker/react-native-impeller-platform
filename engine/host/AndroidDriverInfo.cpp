#include "host/AndroidDriverInfo.h"

#include <cstring>

namespace rni::android {
namespace {

// android_context_dynamic_impeller.cc kBadSocs, matched against
// ro.product.board exactly like IsKnownBadSOC.
struct BadSoc {
  const char* board;
  const char* why;
};
constexpr BadSoc kBadSocs[] = {
    // "Most Exynos Series SoC. These are SoCs that crash when using AHB imports."
    {"exynos7870", "exynos_ahb_import_crash"},
    {"exynos7880", "exynos_ahb_import_crash"},
    {"exynos7872", "exynos_ahb_import_crash"},
    {"exynos7884", "exynos_ahb_import_crash"},
    {"exynos7885", "exynos_ahb_import_crash"},
    {"exynos7904", "exynos_ahb_import_crash"},
    // Mongoose line (same AHB import crash).
    {"exynos8890", "exynos_mongoose_ahb_import_crash"},
    {"exynos8895", "exynos_mongoose_ahb_import_crash"},
    {"exynos9609", "exynos_mongoose_ahb_import_crash"},
    {"exynos9610", "exynos_mongoose_ahb_import_crash"},
    {"exynos9611", "exynos_mongoose_ahb_import_crash"},
    {"exynos9810", "exynos_mongoose_ahb_import_crash"},
    // https://github.com/flutter/flutter/issues/171992 (graphical errors)
    {"exynos9820", "flutter#171992"},
    {"exynos9825", "flutter#171992"},
    // https://github.com/flutter/flutter/issues/183510
    {"rk30sdk", "flutter#183510"},
};

// driver_info_vk.cc kAdrenoVersions entries whose AdrenoGPU enum value is
// <= kAdreno650 (the enum is ordered by generation, not by number).
// https://github.com/flutter/flutter/issues/178285
// https://github.com/flutter/flutter/issues/178498
constexpr const char* kAdrenoAtMost650[] = {
    "504", "505", "506", "508", "509", "510", "512", "530", "540",
    "605", "608", "610", "612", "613", "615", "616", "618", "619L",
    "619", "620", "630", "640", "642L", "642", "643L", "644", "650",
};

// driver_info_vk.cc kGpuSeriesMap; anything else is kUnknown or kRogue.
constexpr const char* kPowerVrBxeOrNewer[] = {"BXE", "BXM", "BXS",
                                              "BXT", "CXT", "DXT"};

// driver_info_vk.cc IdentifyVendor PCI IDs.
constexpr uint32_t kVendorImgTec = 0x1010;  // VendorVK::kPowerVR
constexpr uint32_t kVendorQualcomm = 0x5143;
constexpr uint32_t kVendorHuawei = 0x19E5;
constexpr uint32_t kVendorSamsung = 0x144D;

// driver_info_vk.cc kPixel10DeviceID / kPixel10MinDriverVersion (25.1).
constexpr uint32_t kPixel10DeviceId = 0x71061212;
constexpr uint32_t kPixel10MinDriverVersion = 6794074;

constexpr uint32_t ApiVersion(uint32_t major, uint32_t minor) {
  return (major << 22U) | (minor << 12U);  // VK_MAKE_API_VERSION(0, M, m, 0)
}

// GetAdrenoVersion: "Adreno (TM) VERSION", exact map lookup.
bool IsAdrenoAtMost650(const std::string& name) {
  const auto pos = name.find("Adreno (TM) ");
  if (pos == std::string::npos) return false;
  const std::string version = name.substr(pos + 12);
  for (const char* v : kAdrenoAtMost650) {
    if (version == v) return true;
  }
  return false;
}

bool IsPowerVrBxeOrNewer(const std::string& name) {
  for (const char* series : kPowerVrBxeOrNewer) {
    if (name.find(series) != std::string::npos) return true;
  }
  return false;
}

bool IsEmulator(const DeviceProps& p) {
  return p.hardware == "goldfish" || p.hardware == "ranchu" ||
         p.hardware == "qemu" ||
         p.model.find("gphone") != std::string::npos || p.qemu_pipe;
}

}  // namespace

const char* PlatformDenyReason(const DeviceProps& p) {
  if (p.api_level < kMinApiLevelForVulkan) return "api_level<29";
  if (IsEmulator(p)) return "emulator";
  // "AHB imports do not consistently work" on Huawei.
  if (p.client_id_base == "android-huawei") return "huawei_ahb_import";
  const int vendor_api = p.vendor_api_level >= 0 ? p.vendor_api_level
                                                 : p.api_level;
  if (vendor_api < 32 && p.mediatek) return "mediatek_vendor_api<32";
  for (const auto& soc : kBadSocs) {
    if (p.board == soc.board) return soc.why;
  }
  return nullptr;
}

const char* KnownBadDriverReason(const VkDriverIdentity& id) {
  if (id.vendor_id == kVendorImgTec && id.device_id == kPixel10DeviceId &&
      id.driver_version < kPixel10MinDriverVersion) {
    return "pixel10_powervr_driver<25.1";
  }
  if (id.vendor_id == kVendorQualcomm && IsAdrenoAtMost650(id.device_name)) {
    return "adreno<=650(flutter#178285,#178498)";
  }
  if (id.vendor_id == kVendorHuawei) return "huawei_maleoon(flutter#156623)";
  if (id.vendor_id == kVendorSamsung) {
    // Xclipse first generation; Vulkan 1.3 is the proxy (flutter#161334).
    return id.api_version < ApiVersion(1, 3) ? "samsung_xclipse_vk<1.3(flutter#161334)"
                                             : nullptr;
  }
  if (id.vendor_id == kVendorImgTec && !IsPowerVrBxeOrNewer(id.device_name)) {
    // flutter#161122, #160960, #160866, #160804, #160406
    return "powervr<BXE(flutter#161122)";
  }
  return nullptr;
}

VkDriverIdentity ForcedBadDriverIdentity() {
  VkDriverIdentity id;
  id.vendor_id = kVendorQualcomm;
  id.device_id = 0x06050001;
  id.api_version = ApiVersion(1, 1);
  id.device_type = 1;  // VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
  id.device_name = "Adreno (TM) 650";
  return id;
}

}  // namespace rni::android
