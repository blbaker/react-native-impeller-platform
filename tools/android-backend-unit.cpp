// FP-25 host unit test for engine/host/AndroidDriverInfo.cpp (no device):
// every Flutter deny-list entry rejects Vulkan, and its nearest good neighbour
// does not. Built and run by tools/ci-android-backend.sh with the host c++.
#include <cstdio>
#include <string>

#include "host/AndroidDriverInfo.h"

using rni::android::DeviceProps;
using rni::android::KnownBadDriverReason;
using rni::android::PlatformDenyReason;
using rni::android::VkDriverIdentity;

namespace {
int failures = 0;

void Expect(bool bad, const char* reason, const std::string& what) {
  const bool got_bad = reason != nullptr;
  if (got_bad != bad) {
    std::printf("UNIT_FAIL %s: expected %s, got %s\n", what.c_str(),
                bad ? "deny" : "allow", reason ? reason : "allow");
    failures++;
  }
}

DeviceProps Good() {
  DeviceProps p;
  p.api_level = 33;
  p.hardware = "qcom";
  p.model = "SM-G991U1";
  p.board = "lahaina";
  return p;
}

VkDriverIdentity Gpu(uint32_t vendor, const char* name, uint32_t major = 1,
                     uint32_t minor = 1) {
  VkDriverIdentity id;
  id.vendor_id = vendor;
  id.device_name = name;
  id.api_version = (major << 22U) | (minor << 12U);
  return id;
}
}  // namespace

int main() {
  int cases = 0;
  auto plat = [&](bool bad, DeviceProps p, const std::string& what) {
    cases++;
    Expect(bad, PlatformDenyReason(p), what);
  };
  auto drv = [&](bool bad, VkDriverIdentity id, const std::string& what) {
    cases++;
    Expect(bad, KnownBadDriverReason(id), what);
  };

  plat(false, Good(), "S21 props");
  DeviceProps p = Good();
  p.api_level = 28;
  plat(true, p, "api 28");
  for (const char* hw : {"goldfish", "ranchu", "qemu"}) {
    p = Good(); p.hardware = hw; plat(true, p, std::string("emulator ") + hw);
  }
  p = Good(); p.model = "sdk_gphone64_arm64"; plat(true, p, "gphone model");
  p = Good(); p.qemu_pipe = true; plat(true, p, "qemu_pipe");
  p = Good(); p.client_id_base = "android-huawei"; plat(true, p, "huawei");
  p = Good(); p.mediatek = true; p.vendor_api_level = 31; plat(true, p, "mediatek 31");
  p = Good(); p.mediatek = true; p.vendor_api_level = 32; plat(false, p, "mediatek 32");
  p = Good(); p.mediatek = true; p.api_level = 31; plat(true, p, "mediatek api 31 no vendor sdk");
  for (const char* soc : {"exynos7870", "exynos7880", "exynos7872", "exynos7884",
                          "exynos7885", "exynos7904", "exynos8890", "exynos8895",
                          "exynos9609", "exynos9610", "exynos9611", "exynos9810",
                          "exynos9820", "exynos9825", "rk30sdk"}) {
    p = Good(); p.board = soc; plat(true, p, std::string("soc ") + soc);
  }
  p = Good(); p.board = "exynos2100"; plat(false, p, "soc exynos2100");

  constexpr uint32_t kQcom = 0x5143, kImg = 0x1010, kHuawei = 0x19E5, kSamsung = 0x144D;
  for (const char* v : {"504", "505", "506", "508", "509", "510", "512", "530", "540",
                        "605", "608", "610", "612", "613", "615", "616", "618", "619L",
                        "619", "620", "630", "640", "642L", "642", "643L", "644", "650"}) {
    drv(true, Gpu(kQcom, (std::string("Adreno (TM) ") + v).c_str()), std::string("adreno ") + v);
  }
  for (const char* v : {"660", "663", "675", "690", "730", "740", "750", "X185", "999"}) {
    drv(false, Gpu(kQcom, (std::string("Adreno (TM) ") + v).c_str()), std::string("adreno ") + v);
  }
  drv(true, Gpu(kHuawei, "Maleoon 910"), "huawei maleoon");
  drv(true, Gpu(kSamsung, "Samsung Xclipse 920", 1, 1), "xclipse vk 1.1");
  drv(false, Gpu(kSamsung, "Samsung Xclipse 940", 1, 3), "xclipse vk 1.3");
  drv(true, Gpu(kImg, "PowerVR Rogue GE8320"), "powervr rogue");
  drv(false, Gpu(kImg, "PowerVR B-Series BXM-8-256"), "powervr BXM");
  VkDriverIdentity pixel10 = Gpu(kImg, "PowerVR D-Series DXT-48-1536");
  pixel10.device_id = 0x71061212;
  pixel10.driver_version = 6794073;
  drv(true, pixel10, "pixel10 old driver");
  pixel10.driver_version = 6794074;
  drv(false, pixel10, "pixel10 25.1 driver");
  drv(false, Gpu(0x13B5, "Mali-G78"), "mali G78");
  drv(true, rni::android::ForcedBadDriverIdentity(), "forced identity");

  if (failures != 0) {
    std::printf("ANDROID_BACKEND_UNIT_FAIL %d of %d cases\n", failures, cases);
    return 1;
  }
  std::printf("ANDROID_BACKEND_UNIT_PASS cases=%d\n", cases);
  return 0;
}
