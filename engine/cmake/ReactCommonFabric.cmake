# =============================================================================
# ReactCommonFabric.cmake — RN 0.86.2's Fabric renderer + Yoga, compiled in
# place from engine/rn/node_modules.
#
# Platform selector rule (D1): wherever upstream has a platform/ split we take
# platform/cxx. android/ios/tvos dirs, tests/, and Perfetto are excluded.
#
# P2 component scope: root, view, text (+scrollview, which is NOT optional —
# mounting/internal/CullingContext.cpp hard-includes ScrollViewShadowNode.h for
# a dynamic_cast, so its sources must compile even before we mount one).
# =============================================================================

set(RC "${REACT_COMMON}")
set(RR "${RC}/react/renderer")

# ---- yoga -------------------------------------------------------------------
file(GLOB_RECURSE yoga_SRC ${RC}/yoga/yoga/*.cpp)

# ---- renderer ---------------------------------------------------------------
file(GLOB rr_core_SRC              ${RR}/core/*.cpp)
file(GLOB rr_graphics_SRC          ${RR}/graphics/*.cpp)
file(GLOB rr_componentregistry_SRC ${RR}/componentregistry/*.cpp)
file(GLOB rr_componentregistry_native_SRC ${RR}/componentregistry/native/*.cpp)
file(GLOB rr_comp_root_SRC         ${RR}/components/root/*.cpp)
file(GLOB rr_comp_view_SRC         ${RR}/components/view/*.cpp)
file(GLOB rr_comp_scrollview_SRC   ${RR}/components/scrollview/*.cpp)
file(GLOB rr_comp_text_SRC         ${RR}/components/text/*.cpp)
# <TextInput>. ENG-01b. The base sources (props/eventemitter) plus the iOS
# platform variant — the metro shim redirects TextInput.js down its iOS arm, so
# RCTSinglelineTextInputView's descriptor is iostextinput/, exactly as <Text>
# takes text/platform/cxx. Without these the "TextInput" name has no registered
# ComponentDescriptor and the field mounts as a plain View: it lays out, paints
# its border, and swallows every keystroke — indistinguishable from a read-only
# surface, which is the ENG-01 disease this closes.
file(GLOB rr_comp_textinput_SRC    ${RR}/components/textinput/*.cpp)
file(GLOB rr_comp_iostextinput_SRC ${RR}/components/textinput/platform/ios/react/renderer/components/iostextinput/*.cpp)
# <Switch>. ENG-15. RN's generated core-component Props + EventEmitters
# (SwitchProps, SwitchEventEmitter::onChange). Only these two files: they
# depend on nothing beyond view/core/graphics, which are already here. RN's own
# Switch ShadowNode is NOT used (it measures through UIKit/AppKit .mm); ours is
# engine/fabric/SwitchShadowNode.h. The other props classes in these files
# (Modal, ActivityIndicator, ...) compile but stay unregistered.
set(rr_fbspec_DIR "${RN_ROOT}/React/FBReactNativeSpec/react/renderer/components/FBReactNativeSpec")
set(rr_comp_switch_SRC ${rr_fbspec_DIR}/Props.cpp ${rr_fbspec_DIR}/EventEmitters.cpp)
file(GLOB rr_mounting_SRC          ${RR}/mounting/*.cpp)
file(GLOB rr_mounting_internal_SRC ${RR}/mounting/internal/*.cpp)
file(GLOB rr_mounting_stubs_SRC    ${RR}/mounting/stubs/*.cpp)
file(GLOB rr_scheduler_SRC         ${RR}/scheduler/*.cpp)
file(GLOB rr_uimanager_SRC         ${RR}/uimanager/*.cpp)
file(GLOB rr_uimanager_consistency_SRC ${RR}/uimanager/consistency/*.cpp)
file(GLOB rr_attributedstring_SRC  ${RR}/attributedstring/*.cpp)
file(GLOB rr_tlm_SRC               ${RR}/textlayoutmanager/*.cpp)
file(GLOB rr_tlm_cxx_SRC           ${RR}/textlayoutmanager/platform/cxx/react/renderer/textlayoutmanager/*.cpp)
file(GLOB rr_imagemanager_SRC      ${RR}/imagemanager/*.cpp)
# A19 (SC-30): OUR ImageManager (decodes local sources) replaces the cxx stub,
# and RN's components/image (ImageShadowNode, ImageProps) is compiled.
set(rr_imagemanager_cxx_SRC
  ${CMAKE_SOURCE_DIR}/fabric/platform/impeller/react/renderer/imagemanager/ImageManager.cpp
  ${CMAKE_SOURCE_DIR}/fabric/ImageStore.cpp
  ${CMAKE_SOURCE_DIR}/fabric/ImageCache.cpp
  ${CMAKE_SOURCE_DIR}/fabric/ImageBudget.cpp
  # FP-16: IO pool, streaming PNG rows, area downscale
  ${CMAKE_SOURCE_DIR}/fabric/ImageSource.cpp
  ${CMAKE_SOURCE_DIR}/fabric/ImageFetch.cpp
  ${CMAKE_SOURCE_DIR}/fabric/ImageDecode.cpp
  ${CMAKE_SOURCE_DIR}/fabric/ImageResize.cpp
  ${CMAKE_SOURCE_DIR}/fabric/ImageIoPool.cpp
  ${CMAKE_SOURCE_DIR}/fabric/PngStream.cpp
  ${CMAKE_SOURCE_DIR}/fabric/Inflate.cpp)
file(GLOB rr_comp_image_SRC        ${RR}/components/image/*.cpp)
file(GLOB rr_telemetry_SRC         ${RR}/telemetry/*.cpp)
file(GLOB rr_leakchecker_SRC       ${RR}/leakchecker/*.cpp)
file(GLOB rr_animations_SRC        ${RR}/animations/*.cpp)
file(GLOB rr_css_SRC               ${RR}/css/*.cpp)
file(GLOB rr_dom_SRC               ${RR}/dom/*.cpp)
file(GLOB rr_element_SRC           ${RR}/element/*.cpp)
file(GLOB rr_observers_events_SRC  ${RR}/observers/events/*.cpp)
# The Intersection/Mutation observer MANAGERS are the implementation behind the
# NativeIntersectionObserver / NativeMutationObserver TurboModules that
# DefaultTurboModules vends. Same link-time rule as renderer/animated: the
# feature flags gating them are read at runtime, so the symbols are required
# whether or not the flag is ever true.
file(GLOB rr_observers_intersection_SRC ${RR}/observers/intersection/*.cpp)
file(GLOB rr_observers_mutation_SRC     ${RR}/observers/mutation/*.cpp)
# Scheduler.cpp references AnimationBackend/AnimationChoreographer and
# ViewTransitionModule even when the gating feature flags are off — link-time
# deps, so they compile regardless.
file(GLOB rr_animationbackend_SRC  ${RR}/animationbackend/*.cpp)
file(GLOB rr_viewtransition_SRC    ${RR}/viewtransition/*.cpp)
file(GLOB rr_cdpmetrics_SRC        ${RC}/react/performance/cdpmetrics/*.cpp)
# ComponentDescriptorRegistry.cpp pulls these in once Scheduler is real.
file(GLOB rr_legacyinterop_SRC     ${RR}/components/legacyviewmanagerinterop/*.cpp)

# Deliberately NOT here:
#  - renderer/{debug,consistency,runtimescheduler}: already in reactcommon_core,
#    re-adding duplicates symbols.
#  - components/{image,textinput,modal,...}: land with their features.
#
# renderer/animated/ IS here as of P4, and NOT because we implemented
# animations. Delegating TurboModule lookup to RN's own
# `DefaultTurboModules::getTurboModule` (P4's seam) puts a direct reference to
# `AnimatedModule::kModuleName` and its ctor on the link line — the gating
# feature flags are checked at RUNTIME, so the symbol is required at LINK time
# regardless of whether the flag is ever true. 29 files, all portable C++ (0
# JNI/ObjC matches), so this is the cheap half of "use the in-tree engine
# rather than scoping a third-party animation library". The JS-facing feature
# stays off until an animation phase turns the flags on.
file(GLOB rr_animated_SRC          ${RR}/animated/*.cpp)
file(GLOB rr_animated_nodes_SRC    ${RR}/animated/nodes/*.cpp)
file(GLOB rr_animated_drivers_SRC  ${RR}/animated/drivers/*.cpp)
file(GLOB rr_animated_evdrv_SRC    ${RR}/animated/event_drivers/*.cpp)
file(GLOB rr_animated_internal_SRC ${RR}/animated/internal/*.cpp)

set(reactcommon_fabric_SRC
  ${yoga_SRC}
  ${rr_core_SRC} ${rr_graphics_SRC}
  ${rr_componentregistry_SRC} ${rr_componentregistry_native_SRC}
  ${rr_comp_root_SRC} ${rr_comp_view_SRC} ${rr_comp_scrollview_SRC} ${rr_comp_text_SRC}
  ${rr_comp_textinput_SRC} ${rr_comp_iostextinput_SRC} ${rr_comp_switch_SRC}
  ${rr_mounting_SRC} ${rr_mounting_internal_SRC} ${rr_mounting_stubs_SRC}
  ${rr_scheduler_SRC} ${rr_uimanager_SRC} ${rr_uimanager_consistency_SRC}
  ${rr_attributedstring_SRC} ${rr_tlm_SRC} ${rr_tlm_cxx_SRC}
  ${rr_imagemanager_SRC} ${rr_imagemanager_cxx_SRC} ${rr_comp_image_SRC}
  ${rr_telemetry_SRC} ${rr_leakchecker_SRC} ${rr_animations_SRC}
  ${rr_css_SRC} ${rr_dom_SRC} ${rr_element_SRC} ${rr_observers_events_SRC}
  ${rr_observers_intersection_SRC} ${rr_observers_mutation_SRC}
  ${rr_animationbackend_SRC} ${rr_viewtransition_SRC} ${rr_cdpmetrics_SRC}
  ${rr_legacyinterop_SRC}
  ${rr_animated_SRC} ${rr_animated_nodes_SRC} ${rr_animated_drivers_SRC}
  ${rr_animated_evdrv_SRC} ${rr_animated_internal_SRC}
  # item 11: the tvos HostPlatformViewProps has a .cpp (cxx is header-only).
  # Style audit item 4: now OUR copy of it (engine/fabric/platform/impeller),
  # which also parses `elevation` (only RN's android variant does).
  ${CMAKE_SOURCE_DIR}/fabric/platform/impeller/react/renderer/components/view/HostPlatformViewProps.cpp
)
# Same targeted Perfetto rule as ReactCommonCore.cmake — see the long comment
# there for why a blanket "Perfetto" filter breaks the non-Perfetto build.
list(FILTER reactcommon_fabric_SRC EXCLUDE REGEX
  "(ReactPerfetto|ReactPerfettoCategories|HermesPerfettoDataSource|FuseboxPerfettoDataSource)\\.cpp$")

add_library(reactcommon_fabric STATIC ${reactcommon_fabric_SRC})

target_include_directories(reactcommon_fabric SYSTEM PUBLIC
  ${RC}/yoga
  # platform/cxx selector roots must precede the generic ${RC} root (PUBLIC on
  # reactcommon_core) so <react/renderer/...> resolves to the cxx variant.
  #
  # desktop-input-gap item 11: View props use upstream's TVOS variant, NOT
  # cxx. The cxx HostPlatformViewProps is a bare alias of BaseViewProps, so
  # the `focusable` prop View.js sends (and that tabIndex is converted into)
  # was parsed by nobody and dropped. tvos/HostPlatformViewProps adds exactly
  # `bool focusable`; its touch/event-emitter headers are identical to cxx and
  # its traits differ only in unused parameter names. TextInputProps derive
  # from ViewProps, so fields get it too (TextInput.js always sends it, false
  # for tabIndex -1).
  # Style audit item 4: the tvos headers are vendored into
  # engine/fabric/platform/impeller with `elevation` added, so that root is
  # used instead of ${RR}/components/view/platform/tvos.
  ${CMAKE_SOURCE_DIR}/fabric/platform/impeller
  ${RR}/graphics/platform/cxx
  ${RR}/textlayoutmanager/platform/cxx
  ${RR}/imagemanager/platform/cxx
  ${RR}/components/scrollview/platform/cxx
  ${RR}/components/text/platform/cxx
  # <TextInput>: the iOS variant's headers are addressed as
  # <react/renderer/components/iostextinput/...>, so its platform root joins the
  # path exactly as text/scrollview's cxx roots do above.
  ${RR}/components/textinput/platform/ios
  ${RC}/react/utils/platform/cxx
)
# imagemanager/platform/cxx/.../ImageManager.cpp does #include "ImageManager.h"
# expecting the top-level imagemanager dir on the path (upstream adds it in the
# pod/gradle build). PRIVATE so it cannot shadow anything downstream.
target_include_directories(reactcommon_fabric PRIVATE ${RR}/imagemanager)
target_include_directories(reactcommon_fabric PRIVATE ${CMAKE_SOURCE_DIR} ${CMAKE_SOURCE_DIR}/fabric ${CMAKE_SOURCE_DIR}/third_party/stb)

# renderer/animated/ includes the codegen'd spec as
# `<FBReactNativeSpec/FBReactNativeSpecJSI.h>` — i.e. via the PARENT directory —
# whereas the host target includes it as a bare `<FBReactNativeSpecJSI.h>`. Both
# spellings appear upstream, so both roots have to be on the path; adding only
# the one you happen to have used gives a "No such file" on a header that is
# plainly right there.
target_include_directories(reactcommon_fabric SYSTEM PRIVATE
  "${RN_ROOT}/React"
  "${RN_ROOT}/React/FBReactNativeSpec"
)

rni_compile_flags(reactcommon_fabric
  EXCEPTIONS RTTI NO_DEPRECATED
  FORCE_INCLUDE cstdint)

target_link_libraries(reactcommon_fabric PUBLIC reactcommon_core)
# core references Fabric symbols too (ReactInstance.cpp calls
# ShadowNode::setUseRuntimeShadowNodeReferenceUpdateOnThread), so declare the
# cycle and let CMake repeat the static libs on the link line.
target_link_libraries(reactcommon_core PUBLIC reactcommon_fabric)
