cmake_minimum_required(VERSION 3.24)
project(rn_impeller_engine CXX C)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")
include(${CMAKE_SOURCE_DIR}/cmake/CompileFlags.cmake)

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

# The Windows SDK is fetched to its OWN directory by tools/sdk-fetch-win.sh:
# `uname` says Linux inside WSL, so one directory cannot serve both, and the two
# have DIFFERENT LAYOUTS — linux ships lib/libimpeller.so (link it directly),
# windows ships lib/impeller.dll + impeller.dll.lib (link the IMPORT lib and
# copy the DLL next to the exe, because Windows has no rpath).
if(WIN32)
  set(_impeller_sdk_default "${CMAKE_SOURCE_DIR}/third_party/impeller-sdk-win")
else()
  set(_impeller_sdk_default "${CMAKE_SOURCE_DIR}/third_party/impeller-sdk")
endif()
set(IMPELLER_SDK "${_impeller_sdk_default}"
    CACHE PATH "Unzipped Impeller standalone SDK (tools/sdk-fetch.sh, sdk-fetch-win.sh)")
if(NOT EXISTS "${IMPELLER_SDK}/include/impeller.h")
  message(FATAL_ERROR "Impeller SDK not found at ${IMPELLER_SDK}. Run: bash tools/sdk-fetch.sh (or sdk-fetch-win.sh)")
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
include(${CMAKE_SOURCE_DIR}/cmake/ReactCommonCore.cmake)
include(${CMAKE_SOURCE_DIR}/cmake/ReactCommonFabric.cmake)

# ---------------------------------------------------------------------------
# The engine host binary. Name and CLI contract are FROZEN by P1 -- the npm
# package's resolver and run-impeller both depend on both.
# ---------------------------------------------------------------------------
add_executable(rn-impeller
  host/main.cpp
  host/Pixel.cpp
  # The offscreen surface, one implementation per platform. Selected here rather
  # than with #ifdefs inside one file: the two share no context-acquisition code
  # at all (Mesa surfaceless EGL vs ANGLE-over-D3D11 loaded by LoadLibrary).
  $<$<NOT:$<BOOL:${WIN32}>>:${CMAKE_SOURCE_DIR}/host/HeadlessSurface.cpp>
  $<$<BOOL:${WIN32}>:${CMAKE_SOURCE_DIR}/host/WinGLSurface.cpp>
  runtime/JsThread.cpp
  runtime/ReactHost.cpp
  modules/PlatformModules.cpp
  fabric/FabricHost.cpp
  scenegraph/SceneGraph.cpp
  text/ImpellerTextLayoutManager.cpp
)

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

if(WIN32)
  # Khronos EGL/GLES3 headers, VENDORED. On Linux these come from the system
  # (libegl-dev / libgles-dev); Windows has no such package and ANGLE's binary
  # redistribution is DLLs only — no headers, no import libs. Vendoring them is
  # ~760 KB of pure declarations and removes a "install these dev packages"
  # step from every Windows build.
  #
  # They are headers ONLY. Nothing links against EGL/GLESv2 on Windows —
  # WinGLSurface resolves every entry point with GetProcAddress — so these
  # supply types, enums and the calling-convention macros, and no symbols.
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
             NO_DEFAULT_PATH REQUIRED)

target_link_libraries(rn-impeller PRIVATE
  reactcommon_fabric
  reactcommon_core
  "${HERMESVM_LIB}"
  "${IMPELLER_LINK_LIB}"
)
if(WIN32)
  # NO ANGLE HERE ON PURPOSE. libEGL/libGLESv2 ship without import libraries,
  # so there is nothing to link; WinGLSurface resolves every EGL and GL entry
  # point with LoadLibrary/GetProcAddress. shlwapi/shell32 are for ShellExecuteW
  # in LinkingManager.
  target_link_libraries(rn-impeller PRIVATE shell32 shlwapi)
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
set_target_properties(rn-impeller PROPERTIES
  BUILD_RPATH "${HERMES_BUILD}/lib;${IMPELLER_SDK}/lib"
  INSTALL_RPATH "$ORIGIN"
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
else()
  install(FILES
    "${IMPELLER_RUNTIME}"
    "${HERMES_BUILD}/lib/libhermesvm.so"
    DESTINATION bin COMPONENT engine)
endif()
