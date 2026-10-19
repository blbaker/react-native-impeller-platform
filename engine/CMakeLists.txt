cmake_minimum_required(VERSION 3.24)
project(rn_impeller_engine CXX C)

# ⛔ .mm FILES DO NOT COMPILE UNLESS OBJCXX IS AN ENABLED LANGUAGE.
# Without this, CMake does not recognise host/GlfwCocoaView.mm as a source it
# can build and the failure is a LINK error naming GlfwCocoaLayerBackedView —
# a symbol whose definition is sitting right there in the tree, which reads as
# a namespace or mangling problem rather than a missing language.
if(APPLE)
  enable_language(OBJCXX)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

if(ANDROID)
  # SC-41: the NDK defines ANDROID, which switches RN's C++ to its RN-Android
  # branches (rawProps, ImageRequestParams). We are the impeller platform;
  # real OS checks use __ANDROID__.
  add_compile_options(-UANDROID)
endif()
list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")
include(${CMAKE_SOURCE_DIR}/cmake/CompileFlags.cmake)
include(${CMAKE_SOURCE_DIR}/cmake/Sanitize.cmake)

# ---------------------------------------------------------------------------
# iOS (Phase 1, Task 1.6). An iOS configure (-DCMAKE_SYSTEM_NAME=iOS) builds
# only the iOS platform library: Metal only, no GLFW, no ANGLE, none of the
# desktop host below. Everything iOS lives in ios/RniIos.cmake.
# ---------------------------------------------------------------------------
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  include(${CMAKE_SOURCE_DIR}/ios/RniIos.cmake)
  return()
endif()

# ---------------------------------------------------------------------------
# P9-A: windowed WSI. Default ON everywhere. Linux and APPLE consume a GLFW
# built by tools/glfw-fetch.sh; Windows builds the same GLFW 3.4 source from
# this configure (see the GLFW block below) and reaches GLES3 through ANGLE
# via GLFW's EGL context path.
# ---------------------------------------------------------------------------
option(RNI_WITH_WINDOW "Build GlfwSurface / --window support" ON)

# ---------------------------------------------------------------------------
# MSVC-wide definitions (P5). These are DIRECTORY-scoped on purpose: they must
# reach the FetchContent'd dependencies (folly, glog) as well as our targets,
# and those add_library() calls are made inside included .cmake files we do not
# own.
# ---------------------------------------------------------------------------
if(MSVC)
  add_compile_definitions(
    # <windows.h> defines min/max as FUNCTION-LIKE MACROS. The tell is not the
    # error but a warning: `C4003: not enough arguments for function-like macro
    # invocation 'max'`, followed by `C2589: '(' illegal token on right side of
    # '::'` on a perfectly ordinary std::max( call. Reads like a conformance
    # problem, is a macro collision.
    NOMINMAX
    WIN32_LEAN_AND_MEAN
    # M_PI is POSIX, not ISO C/C++; MSVC only declares it under this.
    _USE_MATH_DEFINES
    # RN_EXPORT expands to __attribute__((visibility("default"))) in 10 headers,
    # which MSVC parses as a declaration, giving thousands of cascading syntax
    # errors and bogus "member function already defined" reports.
    #
    # An EMPTY macro is the CORRECT value here, not a workaround: this is ELF
    # symbol visibility, which is meaningless for a static build on Windows, and
    # __declspec(dllexport) would be actively wrong. Safe as a command-line
    # override because ALL TEN definitions are `#ifndef RN_EXPORT`-guarded —
    # counted by tools/apply-win-patches.sh, which fails the build if a future
    # RN bump adds an unguarded one. Upstream already ships this exact fix in
    # cxxreact/JSBigString.h (`#ifdef _MSC_VER` -> empty) and simply did not
    # apply it to its siblings.
    RN_EXPORT=
  )
endif()

# ---------------------------------------------------------------------------
# Paths
#
# RN_ROOT is engine/rn/node_modules/react-native -- a pin OWNED BY THE ENGINE,
# deliberately not the consumer app's copy. The engine ships as a prebuilt
# binary (D4), so the ReactCommon it was COMPILED against is fixed at build
# time and has nothing to do with whatever RN the consumer installs. Pointing
# this at a consumer app would make the binary's ABI depend on the machine that
# happened to build it.
# ---------------------------------------------------------------------------
set(RN_ROOT "${CMAKE_SOURCE_DIR}/rn/node_modules/react-native"
    CACHE PATH "react-native package the engine compiles ReactCommon from")
set(REACT_COMMON "${RN_ROOT}/ReactCommon")
if(NOT EXISTS "${REACT_COMMON}/jsi/jsi/jsi.h")
  message(FATAL_ERROR
    "ReactCommon not found at ${REACT_COMMON}. Run: (cd engine/rn && npm install --ignore-scripts)")
endif()

# Each target OS gets its OWN SDK directory: `uname` says Linux inside WSL, so
# one directory cannot serve a cross-OS stage, and the three have DIFFERENT
# LAYOUTS — linux ships lib/libimpeller.so (link it directly), windows ships
# lib/impeller.dll + impeller.dll.lib (link the IMPORT lib and copy the DLL next
# to the exe, because Windows has no rpath), darwin ships lib/libimpeller.dylib
# (link directly, @rpath at load time).
if(WIN32)
  set(_impeller_sdk_default "${CMAKE_SOURCE_DIR}/third_party/impeller-sdk-win")
elseif(APPLE)
  set(_impeller_sdk_default "${CMAKE_SOURCE_DIR}/third_party/impeller-sdk-darwin")
else()
  set(_impeller_sdk_default "${CMAKE_SOURCE_DIR}/third_party/impeller-sdk")
endif()
set(IMPELLER_SDK "${_impeller_sdk_default}"
    CACHE PATH "Unzipped Impeller standalone SDK (tools/sdk-fetch.sh, sdk-fetch-win.sh, sdk-fetch-darwin.sh)")
# SC-32 custom SDK (letter/word spacing, font features, placeholders; built by
# tools/impeller-sdk-custom-build.sh). RNI_IMPELLER_SDK_DIR (env or -D) picks
# any SDK dir; otherwise each desktop takes its custom SDK (impeller-sdk-custom,
# -custom-darwin, -custom-win; SC-35) when it is built and the stock SDK when it
# is not. Re-derived on every configure because IMPELLER_SDK is a cache
# variable. Android passes IMPELLER_SDK itself.
if(WIN32)
  set(_impeller_sdk_custom "${CMAKE_SOURCE_DIR}/third_party/impeller-sdk-custom-win")
elseif(APPLE)
  set(_impeller_sdk_custom "${CMAKE_SOURCE_DIR}/third_party/impeller-sdk-custom-darwin")
else()
  set(_impeller_sdk_custom "${CMAKE_SOURCE_DIR}/third_party/impeller-sdk-custom")
endif()
if(NOT "$ENV{RNI_IMPELLER_SDK_DIR}" STREQUAL "")
  set(RNI_IMPELLER_SDK_DIR "$ENV{RNI_IMPELLER_SDK_DIR}")
endif()
if(RNI_IMPELLER_SDK_DIR)
  get_filename_component(_rni_sdk "${RNI_IMPELLER_SDK_DIR}" ABSOLUTE BASE_DIR "${CMAKE_SOURCE_DIR}/..")
  set(IMPELLER_SDK "${_rni_sdk}" CACHE PATH "" FORCE)
elseif(NOT ANDROID)
  if(EXISTS "${_impeller_sdk_custom}/include/impeller.h")
    set(IMPELLER_SDK "${_impeller_sdk_custom}" CACHE PATH "" FORCE)
  else()
    set(IMPELLER_SDK "${_impeller_sdk_default}" CACHE PATH "" FORCE)
  endif()
endif()
message(STATUS "Impeller SDK: ${IMPELLER_SDK}")
if(NOT EXISTS "${IMPELLER_SDK}/include/impeller.h")
  message(FATAL_ERROR "Impeller SDK not found at ${IMPELLER_SDK}. Run: bash tools/sdk-fetch.sh (or sdk-fetch-win.sh / sdk-fetch-darwin.sh)")
endif()

if(WIN32)
  set(IMPELLER_LINK_LIB "${IMPELLER_SDK}/lib/impeller.dll.lib")
  set(IMPELLER_RUNTIME  "${IMPELLER_SDK}/lib/impeller.dll")
  # ANGLE: the ONLY way to a GLES3 context on Windows, and therefore the only
  # way to ImpellerSurfaceCreateWrappedFBONew, which is the SDK's only offscreen
  # surface constructor. Pinned + sha256-verified by tools/angle-fetch.sh.
  # NOT linked — loaded with LoadLibrary at runtime (ANGLE ships no import
  # libraries), so these are staged as runtime files only.
  set(ANGLE_DIR "${CMAKE_SOURCE_DIR}/third_party/angle-win-x64")
  if(NOT EXISTS "${ANGLE_DIR}/libEGL.dll")
    message(FATAL_ERROR "ANGLE not found at ${ANGLE_DIR}. Run: bash tools/angle-fetch.sh")
  endif()
elseif(APPLE)
  set(IMPELLER_LINK_LIB "${IMPELLER_SDK}/lib/libimpeller.dylib")
  set(IMPELLER_RUNTIME  "${IMPELLER_SDK}/lib/libimpeller.dylib")
  # macOS needs ANGLE for the SAME reason Windows does, and it is NOT "no GPU
  # API" — Metal is right there. It is that the only OFFSCREEN surface
  # constructor in the SDK takes a GL framebuffer object.
  # ImpellerSurfaceCreateWrappedMetalDrawableNew needs a CAMetalDrawable, i.e. a
  # CAMetalLayer in a real window, and over SSH `launchctl managername` is
  # `Background` so Cocoa refuses to create one. Every headless frame therefore
  # goes through GLES3, and macOS ships neither GLES nor EGL (its system GL is a
  # frozen desktop 2.1 compatibility profile). ANGLE translates GLES3 onto
  # Metal. Same pinned Electron build as Windows, different asset.
  # Loaded with dlopen at runtime, exactly as Windows LoadLibrary's it.
  set(ANGLE_DIR "${CMAKE_SOURCE_DIR}/third_party/angle-darwin-arm64")
  if(NOT EXISTS "${ANGLE_DIR}/libEGL.dylib")
    message(FATAL_ERROR "ANGLE not found at ${ANGLE_DIR}. Run: ANGLE_PLATFORM=darwin-arm64 bash tools/angle-fetch.sh")
  endif()
else()
  set(IMPELLER_LINK_LIB "${IMPELLER_SDK}/lib/libimpeller.so")
  set(IMPELLER_RUNTIME  "${IMPELLER_SDK}/lib/libimpeller.so")
endif()

set(HERMES_SRC "${CMAKE_SOURCE_DIR}/third_party/hermes"
    CACHE PATH "Hermes checkout (tools/hermes-build.sh)")
set(HERMES_BUILD "${CMAKE_SOURCE_DIR}/third_party/hermes-build"
    CACHE PATH "Hermes build dir (tools/hermes-build.sh)")
if(NOT EXISTS "${HERMES_SRC}/API/hermes/hermes.h")
  message(FATAL_ERROR "Hermes not found at ${HERMES_SRC}. Run: bash tools/hermes-build.sh")
endif()

# ---------------------------------------------------------------------------
# ReactCommon: third-party deps, core, Fabric
# ---------------------------------------------------------------------------
include(${CMAKE_SOURCE_DIR}/cmake/ReactCommonDeps.cmake)
# Under ASan folly's headers call annotate_object_collected_impl, defined here.
if(RNI_SANITIZE MATCHES "address")
  target_sources(folly_runtime PRIVATE ${FOLLY_DIR}/folly/memory/SanitizeLeak.cpp)
endif()
include(${CMAKE_SOURCE_DIR}/cmake/ReactCommonCore.cmake)
include(${CMAKE_SOURCE_DIR}/cmake/ReactCommonFabric.cmake)

# ---------------------------------------------------------------------------
# P9-B/B2: the SVG component tier (react-native-svg codegen + our own `d`
# parser). A separate target/source list on purpose, so a codegen problem
# (missing engine/svg/generated, stale react-native-svg checkout) is its own
# distinct build failure rather than folded into the main link.
# ---------------------------------------------------------------------------
option(RNI_WITH_RNSVG "Build the SVG component tier (RNSVGSvgView/Group/Path)" ON)
if(RNI_WITH_RNSVG)
  include(${CMAKE_SOURCE_DIR}/cmake/RnSvg.cmake)
endif()

# ---------------------------------------------------------------------------
# P10-A: the canvas draw-path bench (tools/ci-canvas.sh).
#
# A STANDALONE target, not part of rn-impeller: it needs no Hermes, no React,
# no Fabric and no bundle -- only EGL and libimpeller. That keeps the question
# it answers ("do Impeller's rect/texture primitives carry the game view's
# measured op mix, and how fast") independent of the whole JS stack, so a
# regression here is unambiguously a renderer regression.
#
# Linux-only for now: it uses surfaceless EGL directly, exactly as the P0
# headless spike does.
#
# ⛔ macOS IS INCLUDED, AND IT NEEDS DIFFERENT WIRING THAN LINUX. There is no
# system EGL on macOS -- Apple ships DESKTOP GL 2.1 and no EGL whatsoever -- so
# this needs the VENDORED Khronos headers and must link ANGLE's dylibs by path
# rather than `-lEGL -lGLESv2`, which resolve to nothing there. Same trap the
# main binary hit after compiling 337 of 355 objects.
#
# Windows is excluded: WinGLSurface loads ANGLE with LoadLibrary rather than
# linking it, so the bench would need its own loader.
if(NOT WIN32)
  add_executable(canvas-bench spike/canvas_bench.cpp)
  target_include_directories(canvas-bench PRIVATE "${IMPELLER_SDK}/include")
  if(APPLE)
    target_include_directories(canvas-bench SYSTEM PRIVATE
      "${CMAKE_SOURCE_DIR}/third_party/khronos")
    target_link_libraries(canvas-bench PRIVATE
      "${IMPELLER_LINK_LIB}"
      "${ANGLE_DIR}/libEGL.dylib"
      "${ANGLE_DIR}/libGLESv2.dylib")
    set_target_properties(canvas-bench PROPERTIES
      BUILD_RPATH "${IMPELLER_SDK}/lib;${ANGLE_DIR}")
  else()
    target_link_libraries(canvas-bench PRIVATE "${IMPELLER_LINK_LIB}" EGL GLESv2)
    set_target_properties(canvas-bench PROPERTIES
      BUILD_RPATH "${IMPELLER_SDK}/lib")
  endif()
endif()

# ---------------------------------------------------------------------------
# The engine host binary. Name and CLI contract are FROZEN by P1 -- the npm
# package's resolver and run-impeller both depend on both.
# ---------------------------------------------------------------------------
# Desktop notifications: one backend per OS (see modules/Notifications.h).
# macOS needs the windowed build, the only one that links Apple's UI frameworks.
if(WIN32)
  set(RNI_NOTIFICATIONS_BACKEND modules/NotificationsWin.cpp)
elseif(APPLE AND RNI_WITH_WINDOW)
  set(RNI_NOTIFICATIONS_BACKEND modules/NotificationsDarwin.mm)
elseif(UNIX AND NOT APPLE AND NOT ANDROID)
  set(RNI_NOTIFICATIONS_BACKEND modules/NotificationsLinux.cpp)
else()
  set(RNI_NOTIFICATIONS_BACKEND modules/NotificationsNull.cpp)
endif()
add_executable(rn-impeller
  host/main.cpp
  host/Pixel.cpp
  host/OsAppearance.cpp
  host/FrameTimings.cpp
  host/FrameScheduler.cpp
  host/BackendSelect.cpp
  host/Prewarm.cpp
  host/FrameItem.cpp
  host/RecordNoGl.cpp
  host/AnimRowProbe.cpp
  host/MemoryPressure.cpp
  host/UniformProbe.cpp
  host/RasterThread.cpp
  host/IoContextEgl.cpp
  host/PoisonProbe.cpp
  host/ExternalTextureProbe.cpp  # FP-42 test hook
  # FP-30: host/main.cpp's CLI parser calls rni::resizeprobe::ParseSequence()
  # unconditionally (it is not inside a windowed-only code path), so this TU
  # must always compile. It has no windowing dependency of its own (string
  # parsing + a mutex) -- it was only ever paired with --resize-after-frames
  # in practice, which made gating it alongside the other windowed-only FP-30
  # files look right until a non-windowed build (RNI_WITH_WINDOW=OFF, the
  # android engine) tried to link and failed with an undefined symbol.
  host/ResizeProbe.cpp
  $<$<BOOL:${RNI_WITH_WINDOW}>:${CMAKE_SOURCE_DIR}/host/WindowRasterizer.cpp>
  $<$<BOOL:${RNI_WITH_WINDOW}>:${CMAKE_SOURCE_DIR}/host/ResizeSync.cpp>
  # FP-32: GPU context loss -> teardown + rebuild (windowed EGL).
  $<$<BOOL:${RNI_WITH_WINDOW}>:${CMAKE_SOURCE_DIR}/host/ContextLoss.cpp>
  $<$<BOOL:${RNI_WITH_WINDOW}>:${CMAKE_SOURCE_DIR}/host/ContextLossGl.cpp>
  $<$<BOOL:${RNI_WITH_WINDOW}>:${CMAKE_SOURCE_DIR}/host/ContextRecovery.cpp>
  $<$<BOOL:${RNI_WITH_WINDOW}>:${CMAKE_SOURCE_DIR}/host/GlfwSurfaceRebuild.cpp>
  # FP-44: platform views (X11 child windows; stubs on other hosts).
  $<$<BOOL:${RNI_WITH_WINDOW}>:${CMAKE_SOURCE_DIR}/host/PlatformViewsX11Gl.cpp>
  $<$<BOOL:${RNI_WITH_WINDOW}>:${CMAKE_SOURCE_DIR}/host/PlatformViewProbeX11.cpp>
  $<$<BOOL:${RNI_WITH_WINDOW}>:${CMAKE_SOURCE_DIR}/host/PartialRepaintGl.cpp>
  base/Trace.cpp
  base/DevToolsFrames.cpp
  base/SanitizerHooks.cpp
  base/GlValidation.cpp
  base/TestSync.cpp
  base/GpuAvailability.cpp
  base/GlLimits.cpp
  base/ProgramCount.cpp
  base/ContextFlags.cpp
  $<$<AND:$<BOOL:${RNI_WITH_WINDOW}>,$<BOOL:${APPLE}>>:${CMAKE_SOURCE_DIR}/host/OsAppearanceDarwin.mm>
  # The offscreen surface, one implementation per platform. Selected here rather
  # than with #ifdefs inside one file: the two share no context-acquisition code
  # at all (Mesa surfaceless EGL vs ANGLE-over-D3D11 loaded by LoadLibrary).
  $<$<NOT:$<BOOL:${WIN32}>>:${CMAKE_SOURCE_DIR}/host/HeadlessSurfaceGl.cpp>
  $<$<BOOL:${WIN32}>:${CMAKE_SOURCE_DIR}/host/WinGLSurface.cpp>
  $<$<BOOL:${RNI_WITH_WINDOW}>:${CMAKE_SOURCE_DIR}/host/GlfwSurface.cpp>
  # The one Objective-C TU: NSWindow -> layer-backed NSView, which is what
  # ANGLE/Metal accepts as a native window. APPLE-only by generator expression
  # so no other platform ever tries to compile Cocoa.
  $<$<AND:$<BOOL:${RNI_WITH_WINDOW}>,$<BOOL:${APPLE}>>:${CMAKE_SOURCE_DIR}/host/GlfwCocoaView.mm>
  # FP-21: native Metal window backend (CAMetalLayer + ImpellerContextCreateMetalNew).
  $<$<AND:$<BOOL:${RNI_WITH_WINDOW}>,$<BOOL:${APPLE}>>:${CMAKE_SOURCE_DIR}/host/MetalSurface.mm>
  $<$<AND:$<BOOL:${RNI_WITH_WINDOW}>,$<BOOL:${APPLE}>>:${CMAKE_SOURCE_DIR}/host/GlfwSurfaceMetal.cpp>
  # FP-27: CVDisplayLink vsync source (FlutterDisplayLink.mm).
  $<$<AND:$<BOOL:${RNI_WITH_WINDOW}>,$<BOOL:${APPLE}>>:${CMAKE_SOURCE_DIR}/host/DisplayLinkDarwin.cpp>
  # FP-23: headless darwin on Metal (offscreen MTLTexture, SDK patch 0005).
  $<$<AND:$<BOOL:${RNI_WITH_WINDOW}>,$<BOOL:${APPLE}>>:${CMAKE_SOURCE_DIR}/host/HeadlessSurfaceMetal.mm>
  runtime/JsThread.cpp
  runtime/ReactHost.cpp
  runtime/EngineSession.cpp
  runtime/InspectorHost.cpp
  runtime/DevToolsTracing.cpp
  modules/PlatformModules.cpp
  # ENG-14: the host's accessibility settings. darwin windowed builds read
  # NSWorkspace (Cocoa is linked only there); every other build answers false.
  modules/AccessibilitySettings.cpp
  $<$<AND:$<BOOL:${RNI_WITH_WINDOW}>,$<BOOL:${APPLE}>>:${CMAKE_SOURCE_DIR}/modules/AccessibilitySettingsDarwin.mm>
  modules/NetworkingModule.cpp
  modules/ImageLoaderModule.cpp
  modules/WebSocketModule.cpp
  modules/ExpoHost.cpp
  # ENG-31: globalThis.crypto.getRandomValues on the OS CSPRNG.
  modules/CryptoGlobal.cpp
  modules/ExpoConstants.cpp
  modules/ExpoFetch.cpp
  modules/NotificationsAppName.cpp
  ${RNI_NOTIFICATIONS_BACKEND}
  fabric/FabricHost.cpp
  fabric/FabricHostTextEdit.cpp
  fabric/ComponentRegistry.cpp
  fabric/LayoutAnimations.cpp
  fabric/ExpoBlurShadowNode.cpp
  scenegraph/SceneGraph.cpp
  scenegraph/SceneGraphContextLoss.cpp
  scenegraph/SceneGraphTextInputHost.cpp
  # FP-42: external textures (Flutter TextureRegistry + TextureLayer).
  scenegraph/TextureRegistry.cpp
  scenegraph/ExternalTexturePaint.cpp
  scenegraph/PlatformViewRecord.cpp  # FP-44
  # FP-43: view snapshots (RNViewShot, SnapshotControllerImpeller).
  scenegraph/SnapshotController.cpp
  scenegraph/SnapshotRecord.cpp
  scenegraph/ImageEncode.cpp
  # Windows: the offscreen's gl* pointers, resolved from ANGLE's libGLESv2.dll
  # (no import library). Own TU so <windows.h> stays out of SceneGraph.cpp.
  $<$<BOOL:${WIN32}>:${CMAKE_SOURCE_DIR}/scenegraph/SceneGraphGlWin.cpp>
  scenegraph/Shadows.cpp
  scenegraph/BackgroundLayers.cpp
  scenegraph/BackgroundTiles.cpp
  scenegraph/BorderRounded.cpp
  scenegraph/Outline.cpp
  scenegraph/ScrollIndicators.cpp
  scenegraph/ActivityIndicator.cpp
  scenegraph/Modal.cpp
  scenegraph/ImagePaint.cpp
  scenegraph/RasterJobs.cpp
  scenegraph/GpuBackend.cpp
  scenegraph/TextureUploaderGl.cpp
  scenegraph/SupersampleBackendGl.cpp
  scenegraph/SnapshotReadbackGl.cpp
  scenegraph/DamageTracker.cpp
  scenegraph/IoUploaderGl.cpp
  scenegraph/ImageEvents.cpp
  scenegraph/TextInputStyle.cpp
  scenegraph/ColorMatrixFilter.cpp
  scenegraph/ContentFilters.cpp
  scenegraph/PrewarmTour.cpp
  scenegraph/BackdropBlur.cpp
  scenegraph/BlendGroup.cpp
  scenegraph/EllipsizeText.cpp
  scenegraph/BorderCurve.cpp
  scenegraph/BorderDashRounded.cpp
  scenegraph/DrawOpLog.cpp
  scenegraph/DrawOpHooks.cpp
  scenegraph/DrawOpHooksObjects.cpp
  text/ImpellerTextLayoutManager.cpp
  text/FontRegistry.cpp
  text/TypographyContexts.cpp
  text/FontFamily.cpp
  text/FontFallback.cpp
  fabric/platform/impeller/PlatformColorTable.cpp
)

# FP-50: the painter's translation units are compiled with scenegraph/DrawOpHook.h force-included, so
# every Impeller builder/paint/path call they make can be recorded (--dump-draw-ops, rni-scenegraph-tests).
# Only .cpp files here: see the note in DrawOpHook.h about inline functions in headers.
set(RNI_DRAWOP_HOOKED
  SceneGraph.cpp Shadows.cpp BackgroundLayers.cpp BorderRounded.cpp Outline.cpp ScrollIndicators.cpp
  ActivityIndicator.cpp Modal.cpp ImagePaint.cpp DamageTracker.cpp ContentFilters.cpp BackdropBlur.cpp
  BlendGroup.cpp BorderCurve.cpp BorderDashRounded.cpp ExternalTexturePaint.cpp PlatformViewRecord.cpp
  SnapshotRecord.cpp)
set(RNI_DRAWOP_HOOKED_PATHS "${CMAKE_SOURCE_DIR}/svg/SvgPath.cpp" "${CMAKE_SOURCE_DIR}/svg/SvgDash.cpp")
foreach(_f IN LISTS RNI_DRAWOP_HOOKED)
  list(APPEND RNI_DRAWOP_HOOKED_PATHS "${CMAKE_SOURCE_DIR}/scenegraph/${_f}")
endforeach()
foreach(_f IN LISTS RNI_DRAWOP_HOOKED_PATHS)
  if(MSVC)
    set_property(SOURCE "${_f}" APPEND PROPERTY COMPILE_OPTIONS "/FI${CMAKE_SOURCE_DIR}/scenegraph/DrawOpHook.h")
  else()
    set_property(SOURCE "${_f}" APPEND PROPERTY COMPILE_OPTIONS "-include" "${CMAKE_SOURCE_DIR}/scenegraph/DrawOpHook.h")
  endif()
endforeach()

target_include_directories(rn-impeller PRIVATE
  ${CMAKE_SOURCE_DIR}
  "${IMPELLER_SDK}/include"
  # Codegen'd CxxSpecs (NativePlatformConstantsIOSCxxSpec etc.) ship PREBUILT
  # in the npm package; we do not run codegen.
  #
  # BOTH roots are required. Upstream spells the include two different ways:
  # a bare `<FBReactNativeSpecJSI.h>` in the nativemodule/ sources, and
  # `<FBReactNativeSpec/FBReactNativeSpecJSI.h>` in devtoolsruntimesettings/
  # and renderer/animated/. Adding only the spelling you happened to hit gives
  # a "No such file" on a header that is plainly present.
  "${RN_ROOT}/React"
  "${RN_ROOT}/React/FBReactNativeSpec"
)

if(WIN32 OR APPLE)
  # Khronos EGL/GLES3 headers, VENDORED. On Linux these come from the system
  # (libegl-dev / libgles-dev); neither Windows nor macOS has such a package,
  # and ANGLE's binary redistribution is shared libraries only — no headers, no
  # import libs. Vendoring them is ~760 KB of pure declarations and removes an
  # "install these dev packages" step from every non-Linux build.
  #
  # ⛔ macOS NEEDS THESE FOR THE SAME REASON WINDOWS DOES, AND IT IS EASY TO
  # ASSUME OTHERWISE. Apple ships OpenGL headers, so <OpenGL/gl.h> exists and a
  # reader concludes "macOS has GL, it's fine". It has DESKTOP GL 2.1 and no
  # EGL whatsoever — HeadlessSurfaceGl.cpp includes <EGL/egl.h> and the darwin
  # build died on exactly that after compiling 337 of 355 objects.
  #
  # They are headers ONLY. Nothing links against EGL/GLESv2 on either platform —
  # the surface implementations resolve every entry point dynamically
  # (GetProcAddress / dlsym) — so these supply types, enums and calling
  # conventions, and no symbols.
  #
  # Includes EGL/eglext_angle.h, which is NOT part of the Khronos eglext.h and
  # is where EGL_PLATFORM_ANGLE_ANGLE and the TYPE_* backend tokens live.
  target_include_directories(rn-impeller SYSTEM PRIVATE
    "${CMAKE_SOURCE_DIR}/third_party/khronos")
endif()

# RN's own CxxSpec-backed TurboModules are ordinary portable sources in the RN
# package, not part of any lib target, so the host compiles them.
#
# ⛔ THE SET IS DICTATED BY DefaultTurboModules.cpp, NOT BY WHAT WE USE. P4
# delegates unknown module names to `DefaultTurboModules::getTurboModule`
# (engine/modules/ModuleRegistry.h explains why: hand-rolling what upstream
# already vends goes stale on the next RN bump with no signal). That one
# function references every module below by ctor, so all of them are LINK-time
# requirements even though several are gated behind runtime feature flags that
# are currently false. P2 hand-rolled Microtasks/DOM/FeatureFlags by name and
# was silently missing Performance and IdleCallbacks entirely.
target_sources(rn-impeller PRIVATE
  "${REACT_COMMON}/react/nativemodule/defaults/DefaultTurboModules.cpp"
  "${REACT_COMMON}/react/nativemodule/dom/NativeDOM.cpp"
  "${REACT_COMMON}/react/nativemodule/featureflags/NativeReactNativeFeatureFlags.cpp"
  "${REACT_COMMON}/react/nativemodule/microtasks/NativeMicrotasks.cpp"
  "${REACT_COMMON}/react/nativemodule/idlecallbacks/NativeIdleCallbacks.cpp"
  "${REACT_COMMON}/react/nativemodule/webperformance/NativePerformance.cpp"
  "${REACT_COMMON}/react/nativemodule/intersectionobserver/NativeIntersectionObserver.cpp"
  "${REACT_COMMON}/react/nativemodule/mutationobserver/NativeMutationObserver.cpp"
  "${REACT_COMMON}/react/nativemodule/viewtransition/NativeViewTransition.cpp"
  # DefaultTurboModules vends DevToolsRuntimeSettingsModule under
  # REACT_NATIVE_DEBUGGER_ENABLED_DEVONLY, which reactcommon_core defines
  # PUBLIC (jsinspector needs it — see ReactCommonCore.cmake). Defining the
  # macro and not compiling the module is a link error naming a symbol nothing
  # in our source mentions.
  "${REACT_COMMON}/react/nativemodule/devtoolsruntimesettings/DevToolsRuntimeSettingsModule.cpp"
  "${REACT_COMMON}/devtoolsruntimesettings/DevToolsRuntimeSettings.cpp"
)

# ---------------------------------------------------------------------------
# GLFW (RNI_WITH_WINDOW): consumed from engine/third_party/glfw/install, built
# from source by tools/glfw-fetch.sh (never re-implemented here — this box has
# no non-interactive sudo, so libglfw3-dev cannot be apt-installed). The
# x11-sysroot -L/-l set, including -lXinerama, matches tools/window-spike.sh
# exactly: the system image ships libXinerama.so.1 with no linkable -dev
# symlink, and glfw-fetch.sh stages one into a repo-local sysroot.
# ---------------------------------------------------------------------------
if(RNI_WITH_WINDOW AND WIN32)
  # Windows: GLFW 3.4 from the vendored source tree, compiled by this same
  # MSVC configure. There is no Windows glfw-fetch step and no prebuilt lib to
  # keep in sync; the static `glfw` target links straight in. GLFW's win32
  # backend needs only system DLLs (user32/gdi32/shell32), and its EGL path
  # LoadLibrary's ANGLE's libEGL.dll/libGLESv2.dll from beside the exe.
  set(GLFW_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
  set(GLFW_BUILD_TESTS OFF CACHE BOOL "" FORCE)
  set(GLFW_BUILD_DOCS OFF CACHE BOOL "" FORCE)
  set(GLFW_INSTALL OFF CACHE BOOL "" FORCE)
  add_subdirectory("${CMAKE_SOURCE_DIR}/third_party/glfw" glfw-win EXCLUDE_FROM_ALL)
  target_compile_definitions(rn-impeller PRIVATE RNI_WITH_WINDOW=1)
  target_link_libraries(rn-impeller PRIVATE glfw)
elseif(RNI_WITH_WINDOW)
  set(GLFW_DIR "${CMAKE_SOURCE_DIR}/third_party/glfw/install")
  if(NOT EXISTS "${GLFW_DIR}/lib/libglfw3.a")
    message(FATAL_ERROR "GLFW not found at ${GLFW_DIR}. Run: bash tools/glfw-fetch.sh")
  endif()
  target_compile_definitions(rn-impeller PRIVATE RNI_WITH_WINDOW=1)
  target_include_directories(rn-impeller PRIVATE "${GLFW_DIR}/include")
  if(APPLE)
    # ⛔ GLFW'S COCOA BACKEND LINKS APPLE FRAMEWORKS, NOT THE X11 SET.
    # There is no libX11 on this platform at all, so falling through to the
    # Linux branch fails with five "library not found" errors that name
    # packages a Mac can never have. This set is what GLFW's own generated
    # glfw3.pc lists for a static Cocoa build.
    #
    # ANGLE's libEGL/libGLESv2 are NOT repeated here — the APPLE branch further
    # down already links them into this same target for HeadlessSurface, and
    # the windowed path calls the identical entry points.
    target_link_libraries(rn-impeller PRIVATE
      "${GLFW_DIR}/lib/libglfw3.a"
      "-framework Cocoa"
      "-framework IOKit"
      "-framework CoreVideo"
      "-framework QuartzCore"
      "-framework Metal"
      "-framework UserNotifications")
    # MetalSurface.mm holds strong ObjC members in a C++ struct: ARC only.
    set_source_files_properties("${CMAKE_SOURCE_DIR}/host/MetalSurface.mm"
      "${CMAKE_SOURCE_DIR}/host/HeadlessSurfaceMetal.mm"
      "${CMAKE_SOURCE_DIR}/modules/NotificationsDarwin.mm"
      PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  else()
    set(X11_SYSROOT "${CMAKE_SOURCE_DIR}/third_party/x11-sysroot")
    target_link_libraries(rn-impeller PRIVATE
      "${GLFW_DIR}/lib/libglfw3.a"
      "-L${X11_SYSROOT}/usr/lib/x86_64-linux-gnu"
      X11 Xrandr Xcursor Xi Xinerama m pthread dl)
  endif()
endif()

rni_compile_flags(rn-impeller EXCEPTIONS RTTI NO_DEPRECATED FORCE_INCLUDE cstdint)

# Hermes. hermesvm carries JSI compiled in.
target_include_directories(rn-impeller SYSTEM PRIVATE
  "${HERMES_SRC}/API"
  "${HERMES_SRC}/API/jsi"
  "${HERMES_SRC}/public"
  "${HERMES_BUILD}/gen"
)
# Expect per-target output-directory DRIFT between platforms: the same target
# lands in lib/ as a shared object on Linux and in API/hermes/ as a static lib
# under MSVC. Search both unconditionally rather than #if-ing them — a link
# directory that does not exist is harmless, and a shared list is one the
# working platform keeps exercising.
find_library(HERMESVM_LIB NAMES hermesvm
             PATHS "${HERMES_BUILD}/lib" "${HERMES_BUILD}/API/hermes"
             NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH REQUIRED)

target_link_libraries(rn-impeller PRIVATE
  reactcommon_fabric
  reactcommon_core
  rc_ssl
  "${HERMESVM_LIB}"
  "${IMPELLER_LINK_LIB}"
)
if(RNI_WITH_RNSVG)
  target_compile_definitions(rn-impeller PRIVATE RNI_WITH_RNSVG=1)
  target_link_libraries(rn-impeller PRIVATE rnsvg_common)
endif()
include(${CMAKE_SOURCE_DIR}/cmake/Fuzz.cmake)
include(${CMAKE_SOURCE_DIR}/cmake/SceneGraphTests.cmake)

# ⛔ SHARED-vs-STATIC IS A PACKAGING DIFFERENCE, AND IT LEAKS INTO OUR LINK LINE.
# `hermesvm` is a SHARED library on Linux — libhermesvm.so has already absorbed
# its 20-odd sibling archives, so linking it alone resolves everything. Under
# MSVC the same target is a STATIC lib, which absorbs nothing, and the engine
# fails with 219 unresolved hermes::vm / llvh symbols that appear nowhere in our
# source.
#
# The fix is NOT to hand-write the missing archives from the error text — that
# reverse-engineers a dependency graph CMake already generated correctly. This
# list is read out of Hermes' OWN build files, from the link line of a binary
# that links the same target we do:
#
#   grep -n "LINK_LIBRARIES = .*hermesvm.lib" hermes-win-build/build.ninja
#   -> bin\hdb.exe (build.ninja:9394), order preserved below, dedup'd.
#
# Re-derive with that command after any Hermes bump; do not edit by hand.
# `winmm` (hermesPlatform timers), `icuuc`/`icuin` (-DUSE_WIN10_ICU) are on that
# same line and are NOT optional — they are Hermes' own system deps, not ours.
if(WIN32)
  set(HERMES_WIN_ARCHIVES
    LLVHSupport jsi hermesVMRuntime hermesADT hermesPlatform
    hermesInternalBytecode hermesHBCBackend hermesInst hermesPublic
    hermesBackend hermesFrontend hermesFrontEndDefs hermesOptimizer
    hermesSourceMap hermesParser hermesAST hermesRegex hermesSupport
    dtoa hermesPlatformUnicode LLVHDemangle)
  file(GLOB_RECURSE _all_hermes_libs "${HERMES_BUILD}/*.lib")
  foreach(_a IN LISTS HERMES_WIN_ARCHIVES)
    # ONE recursive walk, filtered per name — each archive sits in its own
    # nested build subdirectory (lib/VM, external/llvh/lib/Support, ...) and
    # recursing 21 times over a multi-GB build tree is measurably slow.
    # A miss is FATAL at configure with a name, rather than 200 mangled symbols
    # at link.
    set(_lib "")
    foreach(_c IN LISTS _all_hermes_libs)
      get_filename_component(_n "${_c}" NAME_WE)
      if(_n STREQUAL _a)
        set(_lib "${_c}")
        break()
      endif()
    endforeach()
    if(NOT _lib)
      message(FATAL_ERROR
        "Hermes archive ${_a}.lib not found under ${HERMES_BUILD}. "
        "Re-derive the list: grep 'LINK_LIBRARIES = .*hermesvm.lib' build.ninja")
    endif()
    target_link_libraries(rn-impeller PRIVATE "${_lib}")
  endforeach()
  target_link_libraries(rn-impeller PRIVATE winmm icuuc icuin)
endif()

if(WIN32)
  # NO ANGLE HERE ON PURPOSE. libEGL/libGLESv2 ship without import libraries,
  # so there is nothing to link; WinGLSurface resolves every EGL and GL entry
  # point with LoadLibrary/GetProcAddress. shlwapi/shell32 are for ShellExecuteW
  # in LinkingManager. runtimeobject is the WinRT activation API the toast
  # backend (modules/NotificationsWin.cpp) uses.
  target_link_libraries(rn-impeller PRIVATE shell32 shlwapi runtimeobject)
elseif(APPLE)
  # ⛔ SAME REASON AS WINDOWS: DO NOT LINK EGL/GLESv2 BY NAME.
  # ANGLE's macOS redistribution is libEGL.dylib + libGLESv2.dylib with no
  # headers; falling through to the Linux branch would pass `-lEGL -lGLESv2`
  # and fail with "library not found" — the system has neither.
  #
  # Unlike Windows DLLs, a Mach-O dylib IS directly linkable, so HeadlessSurface
  # compiles unchanged (it calls eglGetProcAddress directly) and no macOS
  # equivalent of WinGLSurface is needed.
  #
  # ⚠️ BUT ANGLE'S INSTALL NAME IS `./libEGL.dylib` — measured with `otool -D`,
  # not assumed. That is Electron's convention and it resolves against the
  # PROCESS WORKING DIRECTORY, not the binary. Linked as-is, the packaged engine
  # would load only when launched from its own bin/ and fail everywhere else —
  # the precise class of defect the consumer gate exists to catch. Rewritten to
  # @loader_path at install time below.
  target_link_libraries(rn-impeller PRIVATE
    "${ANGLE_DIR}/libEGL.dylib"
    "${ANGLE_DIR}/libGLESv2.dylib"
    "-framework CoreFoundation"
    "-framework CoreText"
    "-framework Foundation")
else()
  target_link_libraries(rn-impeller PRIVATE EGL GLESv2)
endif()

# $ORIGIN so the packaged binary finds libimpeller.so / libhermesvm.so beside it
# wherever npm unpacks it; the BUILD_RPATH is for running in-tree.
#
# The two are switched by `cmake --install`, which rewrites the rpath — that is
# why packaging goes through install rather than copying build/rn-impeller.
# This box has neither patchelf nor chrpath, and a copied binary keeps absolute
# build-tree rpaths that only resolve on the machine that built it.
#
# macOS spells $ORIGIN as @loader_path; the ELF token is meaningless to dyld.
#
# The second macOS entry is for a standard .app: the executable in
# Contents/MacOS and its dylibs in Contents/Frameworks. With @loader_path
# alone dyld aborts there (rc=134), and every consumer had to run
# `install_name_tool -add_rpath` on a signed binary. The shipped dylibs carry
# @rpath install names (cmake/StageDarwinEngine.cmake), so either layout
# loads: bin/ as npm unpacks it, or MacOS + Frameworks.
if(APPLE)
  set(_install_rpath "@loader_path;@loader_path/../Frameworks")
else()
  set(_install_rpath "$ORIGIN")
endif()
set_target_properties(rn-impeller PROPERTIES
  BUILD_RPATH "${HERMES_BUILD}/lib;${IMPELLER_SDK}/lib;${ANGLE_DIR}"
  INSTALL_RPATH "${_install_rpath}"
  BUILD_WITH_INSTALL_RPATH FALSE
)

# ⚠️ COMPONENT-SCOPED, and that is not cosmetic. FetchContent'd projects (glog,
# fmt, double-conversion, fast_float) register their OWN install rules, so a
# bare `cmake --install` stages their headers, .cmake config files and static
# libs into our npm package — 76 stray files and 2 MB of C++ headers shipped to
# consumers. Naming a component means only these rules run.
install(TARGETS rn-impeller RUNTIME DESTINATION bin COMPONENT engine)
if(WIN32)
  # Windows has NO RPATH. Everything the loader needs must be physically beside
  # the .exe, and a missing DLL kills the process BEFORE main() with no output
  # at all — indistinguishable from an early crash. That is also why ANGLE is
  # installed even though nothing links it: WinGLSurface LoadLibrary's it by
  # bare name, which resolves from the executable's directory first.
  #
  # hermesvm is a STATIC lib under MSVC (see the find_library note above), so
  # unlike Linux there is no hermesvm runtime file to stage.
  install(FILES
    "${IMPELLER_RUNTIME}"
    "${ANGLE_DIR}/libEGL.dll"
    "${ANGLE_DIR}/libGLESv2.dll"
    "${ANGLE_DIR}/LICENSE.electron"
    DESTINATION bin COMPONENT engine)

  # ⛔ THE VC++ RUNTIME IS NOT PART OF WINDOWS. `dumpbin /dependents` on the
  # linked exe lists MSVCP140.dll, VCRUNTIME140.dll and VCRUNTIME140_1.dll —
  # they arrive with Visual Studio or with a redist installer, so they are
  # present on THIS box and absent on a plain consumer machine. The failure is
  # the same silent pre-main() death as a missing impeller.dll: no output, no
  # stderr, an exit code from the loader. Shipping them app-local beside the exe
  # is Microsoft's supported deployment mode and costs ~1.5 MB.
  #
  # Derived from the toolchain via InstallRequiredSystemLibraries rather than
  # hardcoding C:/Devel/VSBuildTools/VC/Redist/MSVC/<version>/... — that path
  # embeds an MSVC version that changes with every VS update, and the pin would
  # rot into "file not found" at install time on the next toolchain bump.
  #
  # _NO_WARNINGS: the module warns when it cannot find the debug CRT, which we
  # never want (Release only, and the debug CRT is not redistributable at all).
  set(CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION bin)
  set(CMAKE_INSTALL_SYSTEM_RUNTIME_COMPONENT engine)
  set(CMAKE_INSTALL_UCRT_LIBRARIES FALSE)   # ucrtbase ships with Windows 10+
  set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)  # we install them ourselves, below
  set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_NO_WARNINGS TRUE)
  include(InstallRequiredSystemLibraries)
  if(NOT CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
    message(FATAL_ERROR
      "InstallRequiredSystemLibraries found no MSVC runtime DLLs to stage. "
      "The engine imports MSVCP140/VCRUNTIME140 and would die before main() on "
      "any machine without Visual Studio installed. Refusing to build a package "
      "that only runs on this box.")
  endif()
  install(FILES ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS}
          DESTINATION bin COMPONENT engine)
elseif(APPLE)
  # macOS DOES have an rpath (@loader_path and ../Frameworks, set above), so unlike Windows the
  # libraries do not have to sit beside the binary for the loader to find
  # them, but they DO have to ship, and their install names have to be fixed.
  #
  # ⛔ HERMES BUILDS A FRAMEWORK ON macOS, AND THE FRAMEWORK MUST NOT SHIP.
  # The artifact is lib/hermesvm.framework/Versions/0/hermesvm; there is no
  # libhermesvm.dylib in the Hermes build tree. A framework's top-level entries
  # are symlinks, and `npm pack` drops symlinks, so 0.1.0 shipped a framework
  # that no .app could sign. Install the framework's BINARY as a flat
  # libhermesvm.dylib instead; cmake/StageDarwinEngine.cmake repoints
  # rn-impeller at it and explains the failure in full.
  install(FILES "${HERMES_BUILD}/lib/hermesvm.framework/Versions/0/hermesvm"
          DESTINATION bin RENAME libhermesvm.dylib COMPONENT engine)
  install(FILES
    "${IMPELLER_RUNTIME}"
    "${ANGLE_DIR}/libEGL.dylib"
    "${ANGLE_DIR}/libGLESv2.dylib"
    "${ANGLE_DIR}/LICENSE.electron"
    DESTINATION bin COMPONENT engine)

  # Install names to @rpath, Hermes repointed, everything re-signed.
  # Runs after the FILES rules above: install rules run in declaration order.
  install(SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/cmake/StageDarwinEngine.cmake"
          COMPONENT engine)
else()
  install(FILES
    "${IMPELLER_RUNTIME}"
    "${HERMES_BUILD}/lib/libhermesvm.so"
    DESTINATION bin COMPONENT engine)
endif()
