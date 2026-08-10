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

set(IMPELLER_SDK "${CMAKE_SOURCE_DIR}/third_party/impeller-sdk"
    CACHE PATH "Unzipped Impeller standalone SDK (tools/sdk-fetch.sh)")
if(NOT EXISTS "${IMPELLER_SDK}/include/impeller.h")
  message(FATAL_ERROR "Impeller SDK not found at ${IMPELLER_SDK}. Run: bash tools/sdk-fetch.sh")
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
  host/HeadlessSurface.cpp
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
find_library(HERMESVM_LIB NAMES hermesvm PATHS "${HERMES_BUILD}/lib" NO_DEFAULT_PATH REQUIRED)

target_link_libraries(rn-impeller PRIVATE
  reactcommon_fabric
  reactcommon_core
  "${HERMESVM_LIB}"
  "${IMPELLER_SDK}/lib/libimpeller.so"
  EGL
  GLESv2
)

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
install(FILES
  "${IMPELLER_SDK}/lib/libimpeller.so"
  "${HERMES_BUILD}/lib/libhermesvm.so"
  DESTINATION bin COMPONENT engine)
