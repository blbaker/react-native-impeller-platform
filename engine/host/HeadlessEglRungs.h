// Linux headless EGL display ladder, with the reason each rung was or was not
// taken (linux matrix M2). HeadlessSurface (headless runs) and the doctor
// (`rn-impeller --doctor`) both open the display through here.
//
//   1 surfaceless  EGL_PLATFORM_SURFACELESS_MESA (Mesa; llvmpipe, Panthor)
//   2 gbm          EGL_PLATFORM_GBM_KHR on a DRM node (libmali has no
//                  surfaceless platform; libgbm is dlopen'd, host/OptionalLibs)
//   3 default      eglGetDisplay(EGL_DEFAULT_DISPLAY); HeadlessSurface binds a
//                  1x1 pbuffer when the driver lacks surfaceless contexts
//
// RNI_EGL_PLATFORM=surfaceless|gbm|default pins one rung; the others report
// `skipped:`. A rung whose hardware is absent on this machine (gbm with no
// openable DRM node) gets verdict UNVERIFIED-ON-HARDWARE: it was not proven,
// and it did not fail either.
#pragma once

#include <string>
#include <vector>

namespace rni::headlessegl {

inline constexpr const char* kUnverified = "UNVERIFIED-ON-HARDWARE";

struct Rung {
  std::string name;     // surfaceless | gbm | default
  std::string result;   // ok | fail:<why> | skipped:<why>
  std::string verdict;  // ok | fail | skipped | UNVERIFIED-ON-HARDWARE
};

struct Report {
  std::string forced;            // RNI_EGL_PLATFORM, "" = not set
  std::string clientExtensions;  // eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS)
  std::vector<Rung> rungs;
  std::string took = "none";     // the rung whose display is in use
  std::string gbmNode;           // DRM node the gbm rung opened
  int major = 0, minor = 0;
  std::string current;           // surfaceless | pbuffer (HeadlessSurface sets it)
};

// Walks the ladder and returns an initialised EGLDisplay, or nullptr
// (EGL_NO_DISPLAY). Fills Last() every call.
void* OpenDisplay();

// The report of this process's most recent OpenDisplay().
Report& Last();

// RNI_EGL_FORCE_PBUFFER=1: bind the 1x1 pbuffer even when the driver offers
// surfaceless contexts, so llvmpipe can run the pbuffer path the default rung
// needs on drivers without EGL_KHR_surfaceless_context.
bool ForcePbuffer();

}  // namespace rni::headlessegl
