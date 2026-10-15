cmake_minimum_required(VERSION 3.24)
project(fp24probe CXX C)
# FP-24 swapchain probe (test harness APK payload). Links the real
# AndroidSurface (FP-25: Vulkan or GLES) so the gate exercises the shipped
# code, not a copy.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(ENGINE "${CMAKE_CURRENT_SOURCE_DIR}/../../engine")
set(GLUE "${ANDROID_NDK}/sources/android/native_app_glue")
add_library(fp24probe SHARED
  probe.cpp
  ${GLUE}/android_native_app_glue.c
  ${ENGINE}/host/AndroidVkSurface.cpp
  ${ENGINE}/host/AndroidGlSurface.cpp
  ${ENGINE}/host/AndroidSurface.cpp
  ${ENGINE}/host/AndroidDriverInfo.cpp
  ${ENGINE}/base/ContextFlags.cpp)
target_include_directories(fp24probe PRIVATE ${ENGINE} ${GLUE} "${IMPELLER_SDK}/include")
target_link_libraries(fp24probe PRIVATE "${IMPELLER_SDK}/lib/libimpeller.so" android log dl EGL)
# NativeActivity looks up ANativeActivity_onCreate by name.
set_target_properties(fp24probe PROPERTIES LINK_FLAGS "-u ANativeActivity_onCreate"
  BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "$ORIGIN")
