cmake_minimum_required(VERSION 3.24)
project(rn_impeller_android CXX C)

# ---------------------------------------------------------------------------
# The Android RENDER library. Not an app.
#
# ⛔ SCOPE, DELIBERATELY: this builds the surface layer only -- ANativeWindow ->
# VkSurfaceKHR -> Impeller swapchain -> pixels -- and NOT the React Native
# runtime (JSI, folly, glog, Fabric, the SceneGraph). Those are the next step
# and are a much larger cross-compile; wiring them in before the WSI chain is
# proven on a real device would mean debugging two unknowns at once, and the
# first one is the only one that can be fatal.
#
# The output is libreactnativeimpeller.so, which a HOST APP loads. The host app
# owns the Activity, the manifest, the Gradle build and the APK.
# ---------------------------------------------------------------------------

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(IMPELLER_SDK "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/impeller-sdk-android"
    CACHE PATH "Android Impeller SDK root")

if(NOT EXISTS "${IMPELLER_SDK}/include/impeller.h")
  message(FATAL_ERROR
    "Android Impeller SDK not found at ${IMPELLER_SDK}. Fetch it with:\n"
    "  RNI_SDK_PLATFORM=android-arm64 tools/sdk-fetch.sh "
    "engine/third_party/impeller-sdk-android")
endif()

add_library(reactnativeimpeller SHARED
  ${CMAKE_CURRENT_SOURCE_DIR}/../host/AndroidVkSurface.cpp
  ${CMAKE_CURRENT_SOURCE_DIR}/../host/AndroidGlSurface.cpp
  ${CMAKE_CURRENT_SOURCE_DIR}/../host/AndroidSurface.cpp
  ${CMAKE_CURRENT_SOURCE_DIR}/../host/AndroidDriverInfo.cpp
  ${CMAKE_CURRENT_SOURCE_DIR}/../host/AndroidJni.cpp
  ${CMAKE_CURRENT_SOURCE_DIR}/../base/ContextFlags.cpp
)

target_include_directories(reactnativeimpeller PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/..
  "${IMPELLER_SDK}/include"
)

# ⛔ libvulkan IS NOT LINKED HERE ON PURPOSE. AndroidVkSurface dlopen()s it, so
# a device without Vulkan fails at ONE surface instead of failing to load the
# whole library. Linking it would also make the .so refuse to load on API < 24.
target_link_libraries(reactnativeimpeller PRIVATE
  "${IMPELLER_SDK}/lib/libimpeller.so"
  android    # ANativeWindow_fromSurface / _acquire / _release
  log        # __android_log_print
  dl         # dlopen/dlsym for libvulkan.so
  EGL        # FP-25 GLES fallback (GL entry points come from eglGetProcAddress)
)

# The prebuilt libimpeller.so has no SONAME matching its install path; without
# this the loader looks for the absolute build-time path at runtime.
set_target_properties(reactnativeimpeller PROPERTIES
  BUILD_WITH_INSTALL_RPATH TRUE
  INSTALL_RPATH "$ORIGIN"
)
