# =============================================================================
# iOS host phase: the engine itself as a static library for iOS (rni_ios_engine).
#
# Included by engine/ios/RniIos.cmake when RNI_IOS_WITH_ENGINE is ON. The same
# runtime/fabric/scenegraph/text/modules sources the desktop rn-impeller binary
# compiles (engine/CMakeLists.txt's add_executable list), minus:
#   - the desktop host (host/main.cpp, GLFW, X11, ANGLE/EGL, Win32 surfaces);
#   - every GL translation unit (scenegraph/*Gl.cpp, base/Gl*.cpp,
#     base/ProgramCount.cpp): iOS is Metal only, and the painter has no GL above
#     the GpuBackend interface (FP-20). engine/ios/GlAbsentIOS.cpp supplies the
#     few GL-side entry points the shared code names, as "no GL here";
#   - modules/AccessibilitySettings.cpp (the iOS reader is AccessibilitySettingsIOS.mm).
# plus ReactCommon (cmake/ReactCommon*.cmake, the same lists as desktop) and
# the iOS pieces from rni_ios_platform. Hermes comes from the iOS xcframework.
#
# The product the iOS host links is ONE archive, librni_ios_all.a (target
# rni_ios_all): this library and every static dependency merged with libtool,
# so a host app needs only it, libimpeller.a and hermesvm.framework.
# =============================================================================

set(RN_ROOT "${CMAKE_SOURCE_DIR}/rn/node_modules/react-native"
    CACHE PATH "react-native package the engine compiles ReactCommon from")
set(REACT_COMMON "${RN_ROOT}/ReactCommon")
if(NOT EXISTS "${REACT_COMMON}/jsi/jsi/jsi.h")
  message(FATAL_ERROR
    "rni-ios: ReactCommon not found at ${REACT_COMMON}. Run: (cd engine/rn && npm install --ignore-scripts)")
endif()
# ReactCommonCore.cmake puts the Hermes API headers on its include path.
set(HERMES_SRC "${CMAKE_SOURCE_DIR}/third_party/hermes" CACHE PATH "Hermes checkout (API headers)")
set(HERMES_BUILD "${CMAKE_BINARY_DIR}/hermes-none" CACHE PATH "unused on iOS")
if(NOT EXISTS "${HERMES_SRC}/API/hermes/hermes.h")
  message(FATAL_ERROR "rni-ios: Hermes checkout not found at ${HERMES_SRC} (tools/hermes-build.sh clones it)")
endif()
set(IMPELLER_SDK "${RNI_IOS_SDK_DIR}")

include(${CMAKE_SOURCE_DIR}/cmake/ReactCommonDeps.cmake)
include(${CMAKE_SOURCE_DIR}/cmake/ReactCommonCore.cmake)
include(${CMAKE_SOURCE_DIR}/cmake/ReactCommonFabric.cmake)
# The SVG tier is not optional in practice: SceneGraph and ComponentRegistry
# reach svg/ and the expo-blur/world descriptors only under RNI_WITH_RNSVG.
include(${CMAKE_SOURCE_DIR}/cmake/RnSvg.cmake)

set(_E ${CMAKE_SOURCE_DIR})
add_library(rni_ios_engine STATIC
  ${_E}/ios/RNIEngine.mm
  ${_E}/ios/GlAbsentIOS.cpp
  ${_E}/host/FrameTimings.cpp ${_E}/host/FrameScheduler.cpp ${_E}/host/FrameItem.cpp
  ${_E}/host/RecordNoGl.cpp ${_E}/host/AnimRowProbe.cpp ${_E}/host/MemoryPressure.cpp
  ${_E}/host/UniformProbe.cpp ${_E}/host/RasterThread.cpp ${_E}/host/PoisonProbe.cpp
  ${_E}/host/ExternalTextureProbe.cpp ${_E}/host/ResizeProbe.cpp
  ${_E}/base/Trace.cpp ${_E}/base/DevToolsFrames.cpp ${_E}/base/SanitizerHooks.cpp
  ${_E}/base/TestSync.cpp ${_E}/base/ContextFlags.cpp
  ${_E}/runtime/JsThread.cpp ${_E}/runtime/ReactHost.cpp ${_E}/runtime/EngineSession.cpp
  ${_E}/runtime/InspectorHost.cpp ${_E}/runtime/DevToolsTracing.cpp
  ${_E}/modules/PlatformModules.cpp ${_E}/modules/NetworkingModule.cpp
  ${_E}/modules/ImageLoaderModule.cpp ${_E}/modules/WebSocketModule.cpp ${_E}/modules/ExpoHost.cpp
  ${_E}/modules/CryptoGlobal.cpp ${_E}/modules/ExpoConstants.cpp ${_E}/modules/ExpoFetch.cpp
  # Notifications answers "unavailable" on iOS (no backend yet).
  ${_E}/modules/NotificationsNull.cpp
  ${_E}/fabric/FabricHost.cpp ${_E}/fabric/ComponentRegistry.cpp ${_E}/fabric/LayoutAnimations.cpp
  ${_E}/fabric/ExpoBlurShadowNode.cpp ${_E}/fabric/platform/impeller/PlatformColorTable.cpp
  ${_E}/scenegraph/SceneGraph.cpp ${_E}/scenegraph/SceneGraphContextLoss.cpp
  ${_E}/scenegraph/TextureRegistry.cpp ${_E}/scenegraph/ExternalTexturePaint.cpp
  ${_E}/scenegraph/PlatformViewRecord.cpp ${_E}/scenegraph/SnapshotController.cpp
  ${_E}/scenegraph/SnapshotRecord.cpp ${_E}/scenegraph/ImageEncode.cpp
  ${_E}/scenegraph/Shadows.cpp ${_E}/scenegraph/BackgroundLayers.cpp
  ${_E}/scenegraph/BackgroundTiles.cpp ${_E}/scenegraph/BorderRounded.cpp
  ${_E}/scenegraph/Outline.cpp ${_E}/scenegraph/ScrollIndicators.cpp
  ${_E}/scenegraph/ActivityIndicator.cpp ${_E}/scenegraph/Modal.cpp
  ${_E}/scenegraph/ImagePaint.cpp ${_E}/scenegraph/RasterJobs.cpp ${_E}/scenegraph/GpuBackend.cpp
  ${_E}/scenegraph/DamageTracker.cpp ${_E}/scenegraph/ImageEvents.cpp
  ${_E}/scenegraph/TextInputStyle.cpp ${_E}/scenegraph/ColorMatrixFilter.cpp
  ${_E}/scenegraph/ContentFilters.cpp ${_E}/scenegraph/PrewarmTour.cpp
  ${_E}/scenegraph/BackdropBlur.cpp ${_E}/scenegraph/BlendGroup.cpp
  ${_E}/scenegraph/EllipsizeText.cpp ${_E}/scenegraph/BorderCurve.cpp
  ${_E}/scenegraph/BorderDashRounded.cpp ${_E}/scenegraph/DrawOpLog.cpp
  ${_E}/scenegraph/DrawOpHooks.cpp ${_E}/scenegraph/DrawOpHooksObjects.cpp
  ${_E}/text/ImpellerTextLayoutManager.cpp ${_E}/text/FontRegistry.cpp
  ${_E}/text/TypographyContexts.cpp ${_E}/text/FontFamily.cpp ${_E}/text/FontFallback.cpp
  # RN's own CxxSpec TurboModules (DefaultTurboModules references them all; see
  # the same list in engine/CMakeLists.txt).
  "${REACT_COMMON}/react/nativemodule/defaults/DefaultTurboModules.cpp"
  "${REACT_COMMON}/react/nativemodule/dom/NativeDOM.cpp"
  "${REACT_COMMON}/react/nativemodule/featureflags/NativeReactNativeFeatureFlags.cpp"
  "${REACT_COMMON}/react/nativemodule/microtasks/NativeMicrotasks.cpp"
  "${REACT_COMMON}/react/nativemodule/idlecallbacks/NativeIdleCallbacks.cpp"
  "${REACT_COMMON}/react/nativemodule/webperformance/NativePerformance.cpp"
  "${REACT_COMMON}/react/nativemodule/intersectionobserver/NativeIntersectionObserver.cpp"
  "${REACT_COMMON}/react/nativemodule/mutationobserver/NativeMutationObserver.cpp"
  "${REACT_COMMON}/react/nativemodule/viewtransition/NativeViewTransition.cpp"
  "${REACT_COMMON}/react/nativemodule/devtoolsruntimesettings/DevToolsRuntimeSettingsModule.cpp"
  "${REACT_COMMON}/devtoolsruntimesettings/DevToolsRuntimeSettings.cpp"
)
# FP-50: the painter's TUs record their Impeller calls (same list as desktop).
foreach(_f SceneGraph Shadows BackgroundLayers BorderRounded Outline ScrollIndicators
           ActivityIndicator Modal ImagePaint DamageTracker ContentFilters BackdropBlur
           BlendGroup BorderCurve BorderDashRounded ExternalTexturePaint PlatformViewRecord
           SnapshotRecord)
  set_property(SOURCE "${_E}/scenegraph/${_f}.cpp" APPEND PROPERTY COMPILE_OPTIONS
    "-include" "${_E}/scenegraph/DrawOpHook.h")
endforeach()
foreach(_f SvgPath SvgDash)
  set_property(SOURCE "${_E}/svg/${_f}.cpp" APPEND PROPERTY COMPILE_OPTIONS
    "-include" "${_E}/scenegraph/DrawOpHook.h")
endforeach()
set_source_files_properties(${_E}/ios/RNIEngine.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_include_directories(rni_ios_engine PRIVATE
  ${_E} "${RN_ROOT}/React" "${RN_ROOT}/React/FBReactNativeSpec")
target_include_directories(rni_ios_engine SYSTEM PRIVATE "${RNI_IOS_SDK_DIR}/include")
rni_compile_flags(rni_ios_engine EXCEPTIONS RTTI NO_DEPRECATED FORCE_INCLUDE cstdint)
target_compile_definitions(rni_ios_engine PRIVATE RNI_WITH_RNSVG=1)
target_link_libraries(rni_ios_engine PUBLIC rnsvg_common reactcommon_fabric reactcommon_core rc_ssl
                                            rni_ios_platform)

# One archive for the host: rni_ios_engine + every static library it pulls in.
set(_rni_ios_parts rni_ios_engine rni_ios_platform rnsvg_common reactcommon_fabric reactcommon_core
    folly_runtime glog double-conversion fmt)
set(_rni_ios_files "")
foreach(_t IN LISTS _rni_ios_parts)
  list(APPEND _rni_ios_files "$<TARGET_FILE:${_t}>")
endforeach()
add_custom_command(OUTPUT "${CMAKE_BINARY_DIR}/librni_ios_all.a"
  COMMAND rm -f "${CMAKE_BINARY_DIR}/librni_ios_all.a"
  COMMAND xcrun libtool -static -no_warning_for_no_symbols
          -o "${CMAKE_BINARY_DIR}/librni_ios_all.a" ${_rni_ios_files}
  DEPENDS ${_rni_ios_parts}
  COMMENT "rni-ios: merging the engine's static libraries into librni_ios_all.a")
add_custom_target(rni_ios_all ALL DEPENDS "${CMAKE_BINARY_DIR}/librni_ios_all.a")
