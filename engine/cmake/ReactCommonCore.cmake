# =============================================================================
# ReactCommonCore.cmake — compiles RN's ReactCommon C++ core in-place from
# engine/rn/node_modules (referenced via ${REACT_COMMON}; nothing is vendored).
#
# Scope, new-arch only (PLAN D1): jsi, callinvoker, runtimeexecutor, cxxreact,
# runtimescheduler, react/runtime (bridgeless ReactInstance + TimerManager),
# TurboModule core, jserrorhandler, react/bridging, plus the support libs they
# transitively need. Fabric proper lives in ReactCommonFabric.cmake.
#
# Excluded everywhere: */platform/{android,ios,tvos}, */tests/, Perfetto.
# =============================================================================

set(RC "${REACT_COMMON}")

set(reactcommon_SRC
  # jsi
  ${RC}/jsi/jsi/jsi.cpp
  ${RC}/jsi/jsi/JSIDynamic.cpp
  ${RC}/jsi/jsi/jsilib-posix.cpp
  # cxxreact (all portable in 0.86.2)
  ${RC}/cxxreact/CxxNativeModule.cpp
  ${RC}/cxxreact/Instance.cpp
  ${RC}/cxxreact/JSBigString.cpp
  ${RC}/cxxreact/JSBundleType.cpp
  ${RC}/cxxreact/JSExecutor.cpp
  ${RC}/cxxreact/JSIndexedRAMBundle.cpp
  ${RC}/cxxreact/MethodCall.cpp
  ${RC}/cxxreact/ModuleRegistry.cpp
  ${RC}/cxxreact/NativeToJsBridge.cpp
  ${RC}/cxxreact/RAMBundleRegistry.cpp
  ${RC}/cxxreact/ReactMarker.cpp
  # jserrorhandler
  ${RC}/jserrorhandler/JsErrorHandler.cpp
  ${RC}/jserrorhandler/StackTraceParser.cpp
  # jsitooling — JSRuntime factory/bindings, required by react/runtime
  ${RC}/jsitooling/react/runtime/JSRuntimeBindings.cpp
  ${RC}/jsitooling/react/runtime/JSRuntimeFactory.cpp
  # react/bridging
  ${RC}/react/bridging/LongLivedObject.cpp
  # TurboModule core
  ${RC}/react/nativemodule/core/ReactCommon/CxxTurboModuleUtils.cpp
  ${RC}/react/nativemodule/core/ReactCommon/TurboModule.cpp
  ${RC}/react/nativemodule/core/ReactCommon/TurboModuleBinding.cpp
  ${RC}/react/nativemodule/core/ReactCommon/TurboModulePerfLogger.cpp
  ${RC}/react/nativemodule/core/ReactCommon/TurboModuleUtils.cpp
  ${RC}/react/nativemodule/core/ReactCommon/TurboModuleWithJSIBindings.cpp
  # runtimeexecutor — cxx platform selector
  ${RC}/runtimeexecutor/platform/cxx/ReactCommon/RuntimeExecutorSyncUIThreadUtils.cpp
  # support libs
  ${RC}/logger/react_native_log.cpp
  # Upstream ships BOTH arms of oscompat with no #ifdef inside them and expects
  # the build system to pick one.
  $<$<NOT:$<BOOL:${WIN32}>>:${RC}/oscompat/OSCompatPosix.cpp>
  $<$<BOOL:${WIN32}>:${RC}/oscompat/OSCompatWindows.cpp>
  ${RC}/react/debug/react_native_assert.cpp
  ${RC}/react/featureflags/ReactNativeFeatureFlags.cpp
  ${RC}/react/featureflags/ReactNativeFeatureFlagsAccessor.cpp
  ${RC}/react/renderer/consistency/ShadowTreeRevisionConsistencyManager.cpp
  ${RC}/react/renderer/debug/DebugStringConvertible.cpp
  ${RC}/react/renderer/debug/DebugStringConvertibleItem.cpp
  ${RC}/react/utils/RunLoopObserver.cpp
  ${RC}/react/utils/Uuid.cpp
  ${RC}/react/utils/jsi-utils.cpp
)

# Dirs whose top-level *.cpp are all portable (tests/ live in subdirs).
file(GLOB rc_runtimescheduler_SRC   ${RC}/react/renderer/runtimescheduler/*.cpp)
file(GLOB rc_runtime_SRC            ${RC}/react/runtime/*.cpp)
file(GLOB rc_perftimeline_SRC       ${RC}/react/performance/timeline/*.cpp)
file(GLOB rc_perflogger_SRC         ${RC}/reactperflogger/reactperflogger/*.cpp)
file(GLOB rc_fusebox_SRC            ${RC}/reactperflogger/fusebox/*.cpp)
file(GLOB rc_inspector_SRC          ${RC}/jsinspector-modern/*.cpp)
file(GLOB rc_inspector_cdp_SRC      ${RC}/jsinspector-modern/cdp/*.cpp)
file(GLOB rc_inspector_tracing_SRC  ${RC}/jsinspector-modern/tracing/*.cpp)
file(GLOB rc_inspector_network_SRC  ${RC}/jsinspector-modern/network/*.cpp)

list(APPEND reactcommon_SRC
  ${rc_runtimescheduler_SRC} ${rc_runtime_SRC} ${rc_perftimeline_SRC}
  ${rc_perflogger_SRC} ${rc_fusebox_SRC}
  ${rc_inspector_SRC} ${rc_inspector_cdp_SRC}
  ${rc_inspector_tracing_SRC} ${rc_inspector_network_SRC}
)

# Perfetto tracing is opt-in upstream (WITH_PERFETTO), and we do not ship it.
#
# ⚠️ BUT `ReactPerfettoLogger.cpp` IS NOT A PERFETTO FILE — it is the SHIM.
# Without WITH_PERFETTO defined it compiles to no-op stubs, and those stubs are
# what PerformanceEntryReporter and RuntimeTargetConsole call unconditionally.
# A blanket EXCLUDE REGEX "Perfetto" therefore removes the very definitions the
# non-Perfetto build needs, and the failure is a link error naming
# ReactPerfettoLogger::isTracing() — which reads like a missing tracing library
# rather than an over-broad filter. Exclude only the files that genuinely
# require the Perfetto SDK.
list(FILTER reactcommon_SRC EXCLUDE REGEX
  "(ReactPerfetto|ReactPerfettoCategories|HermesPerfettoDataSource|FuseboxPerfettoDataSource)\\.cpp$")

# HermesInstance.cpp is the bridgeless JSRuntimeFactory (react::HermesInstance::
# createJSRuntime). It lives under react/runtime/hermes/, which the react/runtime
# glob above does NOT reach (that glob is top-level only).
list(APPEND reactcommon_SRC ${RC}/react/runtime/hermes/HermesInstance.cpp)

# ...and HermesInstance's JSRuntime hands out a HermesRuntimeTargetDelegate for
# the CDP inspector, so the hermes/inspector-modern bridge comes with it. This
# is a REQUIRED dependency of the runtime factory, not an opt-in debugging
# extra: without it the link fails on the delegate's ctor/dtor even in a build
# that never attaches a debugger.
list(APPEND reactcommon_SRC
  ${RC}/hermes/inspector-modern/chrome/HermesRuntimeTargetDelegate.cpp
  ${RC}/hermes/inspector-modern/chrome/HermesRuntimeSamplingProfileSerializer.cpp
)

add_library(reactcommon_core STATIC ${reactcommon_SRC})

target_include_directories(reactcommon_core SYSTEM PUBLIC
  ${RC}
  ${RC}/jsi
  ${RC}/callinvoker
  ${RC}/runtimeexecutor
  ${RC}/runtimeexecutor/platform/cxx
  ${RC}/jsitooling
  ${RC}/react/nativemodule/core
  ${RC}/reactperflogger
  # HermesInstance.cpp (added above) includes <hermes/hermes.h>.
  "${HERMES_SRC}/API"
  "${HERMES_SRC}/API/jsi"
  "${HERMES_SRC}/public"
  "${HERMES_BUILD}/gen"
)

target_compile_definitions(reactcommon_core PUBLIC
  LOG_TAG="ReactNative"
  # ⛔ jsinspector-modern/HostAgent.cpp compiles an EMPTY handleRequest(){} unless
  # this is defined — RN only sets it from its own CMakeLists in Debug builds.
  # Without it the entire CDP chain reports success at every layer and does
  # nothing. MUST be PUBLIC: HostAgent.h and InspectorFlags.cpp branch on it too,
  # so a lib/binary disagreement is an ODR bug.
  REACT_NATIVE_DEBUGGER_ENABLED=1
  REACT_NATIVE_DEBUGGER_ENABLED_DEVONLY=1
)
rni_compile_flags(reactcommon_core
  EXCEPTIONS RTTI NO_DEPRECATED
  # These headers assume <cstdint>/<mutex> arrived transitively on Android/iOS.
  # We do not patch node_modules, so force-include them — on every platform, so
  # the header set is identical everywhere.
  FORCE_INCLUDE cstdint mutex)

target_link_libraries(reactcommon_core PUBLIC folly_runtime)
# ReactNativeFeatureFlagsAccessor's wide atomics lower to libatomic calls with
# GCC/Clang on Linux. MSVC and Apple have no such library and need none.
if(NOT MSVC AND NOT APPLE)
  target_link_libraries(reactcommon_core PUBLIC atomic)
endif()
