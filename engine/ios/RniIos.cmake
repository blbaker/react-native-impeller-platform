# =============================================================================
# iOS Phase 1 (Task 1.6): the IOS branch of engine/CMakeLists.txt.
#
# Selected by an iOS configure (-DCMAKE_SYSTEM_NAME=iOS); engine/CMakeLists.txt
# includes this file and returns before any desktop target. Metal only: no
# GLFW, no ANGLE, no GLES anywhere (docs/eng/ios-platform.md).
#
# Builds rni_ios_platform, the static library of the iOS surface primitives
# (Phase 1 Tasks 1.1-1.5), against the iOS Impeller SDK. The iOS Hermes
# xcframework is resolved and exposed as rni_ios_hermes for the iOS host
# library (Phase 3); nothing in Phase 1 calls Hermes yet, but a configure
# without it is refused now, by name, so the Phase 3 link cannot be the first
# place a missing Hermes shows up.
#
# Inputs (cache, overridable):
#   RNI_IOS_SDK_DIR           the Impeller SDK for this sysroot
#                             (default third_party/impeller-sdk-ios-<variant>,
#                             staged by tools/sdk-fetch-ios.sh)
#   RNI_IOS_HERMES_XCFRAMEWORK  hermesvm.xcframework
#                             (default third_party/hermes-ios/hermesvm.xcframework,
#                             staged by tools/hermes-build-ios.sh)
# =============================================================================

if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
  set(RNI_IOS_VARIANT simulator-arm64)
else()
  set(RNI_IOS_VARIANT arm64)
endif()

set(RNI_IOS_SDK_DIR "${CMAKE_SOURCE_DIR}/third_party/impeller-sdk-ios-${RNI_IOS_VARIANT}"
    CACHE PATH "Impeller interop SDK for this iOS sysroot (include/impeller.h, lib/libimpeller.a)")
set(RNI_IOS_HERMES_XCFRAMEWORK "${CMAKE_SOURCE_DIR}/third_party/hermes-ios/hermesvm.xcframework"
    CACHE PATH "Hermes for iOS (device + simulator slices)")

if(NOT EXISTS "${RNI_IOS_SDK_DIR}/include/impeller.h" OR NOT EXISTS "${RNI_IOS_SDK_DIR}/lib/libimpeller.a")
  message(FATAL_ERROR
    "rni-ios: iOS Impeller SDK (${RNI_IOS_VARIANT}) not found at ${RNI_IOS_SDK_DIR}. "
    "Run: bash tools/sdk-fetch-ios.sh (the iOS SDK is built on the Mac; no prebuilt exists)")
endif()
if(NOT EXISTS "${RNI_IOS_HERMES_XCFRAMEWORK}/Info.plist")
  message(FATAL_ERROR
    "rni-ios: iOS Hermes xcframework not found at ${RNI_IOS_HERMES_XCFRAMEWORK}. "
    "Run: bash tools/hermes-build-ios.sh")
endif()
get_filename_component(_rni_hermes_root "${RNI_IOS_HERMES_XCFRAMEWORK}" DIRECTORY)
if(NOT EXISTS "${_rni_hermes_root}/include/hermes/hermes.h")
  message(FATAL_ERROR
    "rni-ios: Hermes headers not found at ${_rni_hermes_root}/include (hermes/hermes.h). "
    "Run: bash tools/hermes-build-ios.sh")
endif()
foreach(_rni_bad IN ITEMS angle glfw)
  if(RNI_IOS_SDK_DIR MATCHES "${_rni_bad}" OR RNI_IOS_HERMES_XCFRAMEWORK MATCHES "${_rni_bad}")
    message(FATAL_ERROR "rni-ios: ${_rni_bad} has no place in an iOS build")
  endif()
endforeach()
message(STATUS "rni-ios: variant=${RNI_IOS_VARIANT} sysroot=${CMAKE_OSX_SYSROOT} "
               "deployment_target=${CMAKE_OSX_DEPLOYMENT_TARGET}")
message(STATUS "rni-ios: impeller_sdk=${RNI_IOS_SDK_DIR}")
message(STATUS "rni-ios: hermes=${RNI_IOS_HERMES_XCFRAMEWORK}")

add_library(rni_ios_platform STATIC
  ${CMAKE_SOURCE_DIR}/host/MetalSurfaceIOS.mm          # Task 1.1
  ${CMAKE_SOURCE_DIR}/host/DisplayLinkIOS.mm           # Task 1.2
  ${CMAKE_SOURCE_DIR}/host/GpuAvailabilityIOS.mm       # Task 1.3
  ${CMAKE_SOURCE_DIR}/base/GpuAvailability.cpp
  ${CMAKE_SOURCE_DIR}/modules/AccessibilitySettingsIOS.mm  # Task 1.4
  ${CMAKE_SOURCE_DIR}/host/OsAppearanceIOS.mm
  ${CMAKE_SOURCE_DIR}/host/OsAppearance.cpp
  ${CMAKE_SOURCE_DIR}/modules/ClipboardIOS.mm          # Task 1.5
  ${CMAKE_SOURCE_DIR}/host/Pixel.cpp
)
target_include_directories(rni_ios_platform PUBLIC ${CMAKE_SOURCE_DIR})
target_include_directories(rni_ios_platform SYSTEM PUBLIC "${RNI_IOS_SDK_DIR}/include")
target_compile_options(rni_ios_platform PRIVATE
  $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
  -Wall -Wextra -Wno-unused-parameter)
set_target_properties(rni_ios_platform PROPERTIES XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES)
target_link_libraries(rni_ios_platform PUBLIC
  "${RNI_IOS_SDK_DIR}/lib/libimpeller.a"
  "-framework UIKit" "-framework Metal" "-framework MetalPerformanceShaders"
  "-framework QuartzCore" "-framework CoreGraphics" "-framework CoreText"
  "-framework Foundation")

# Hermes for the Phase 3 host library: the xcframework (CMake picks the slice
# for the sysroot) plus the API/JSI headers staged beside it.
add_library(rni_ios_hermes INTERFACE)
target_include_directories(rni_ios_hermes SYSTEM INTERFACE "${_rni_hermes_root}/include")
target_link_libraries(rni_ios_hermes INTERFACE "${RNI_IOS_HERMES_XCFRAMEWORK}")

# The engine itself (ReactCommon + runtime + Fabric + scene graph) for the iOS
# host: engine/ios/RniIosEngine.cmake. OFF builds only the platform library.
option(RNI_IOS_WITH_ENGINE "Build rni_ios_engine (the full engine) for iOS" ON)
if(RNI_IOS_WITH_ENGINE)
  include(${CMAKE_SOURCE_DIR}/ios/RniIosEngine.cmake)
endif()
