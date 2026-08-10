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
file(GLOB rr_imagemanager_cxx_SRC  ${RR}/imagemanager/platform/cxx/react/renderer/imagemanager/*.cpp)
file(GLOB rr_telemetry_SRC         ${RR}/telemetry/*.cpp)
file(GLOB rr_leakchecker_SRC       ${RR}/leakchecker/*.cpp)
file(GLOB rr_animations_SRC        ${RR}/animations/*.cpp)
file(GLOB rr_css_SRC               ${RR}/css/*.cpp)
file(GLOB rr_dom_SRC               ${RR}/dom/*.cpp)
file(GLOB rr_element_SRC           ${RR}/element/*.cpp)
file(GLOB rr_observers_events_SRC  ${RR}/observers/events/*.cpp)
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
#  - renderer/animated/: RN's own NativeAnimated engine, portable C++ — a later
#    phase, but note it exists in-tree so no third-party animation library gets
#    scoped by accident.

set(reactcommon_fabric_SRC
  ${yoga_SRC}
  ${rr_core_SRC} ${rr_graphics_SRC}
  ${rr_componentregistry_SRC} ${rr_componentregistry_native_SRC}
  ${rr_comp_root_SRC} ${rr_comp_view_SRC} ${rr_comp_scrollview_SRC} ${rr_comp_text_SRC}
  ${rr_mounting_SRC} ${rr_mounting_internal_SRC} ${rr_mounting_stubs_SRC}
  ${rr_scheduler_SRC} ${rr_uimanager_SRC} ${rr_uimanager_consistency_SRC}
  ${rr_attributedstring_SRC} ${rr_tlm_SRC} ${rr_tlm_cxx_SRC}
  ${rr_imagemanager_SRC} ${rr_imagemanager_cxx_SRC}
  ${rr_telemetry_SRC} ${rr_leakchecker_SRC} ${rr_animations_SRC}
  ${rr_css_SRC} ${rr_dom_SRC} ${rr_element_SRC} ${rr_observers_events_SRC}
  ${rr_animationbackend_SRC} ${rr_viewtransition_SRC} ${rr_cdpmetrics_SRC}
  ${rr_legacyinterop_SRC}
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
  ${RR}/components/view/platform/cxx
  ${RR}/graphics/platform/cxx
  ${RR}/textlayoutmanager/platform/cxx
  ${RR}/imagemanager/platform/cxx
  ${RR}/components/scrollview/platform/cxx
  ${RR}/components/text/platform/cxx
  ${RC}/react/utils/platform/cxx
)
# imagemanager/platform/cxx/.../ImageManager.cpp does #include "ImageManager.h"
# expecting the top-level imagemanager dir on the path (upstream adds it in the
# pod/gradle build). PRIVATE so it cannot shadow anything downstream.
target_include_directories(reactcommon_fabric PRIVATE ${RR}/imagemanager)

rni_compile_flags(reactcommon_fabric
  EXCEPTIONS RTTI NO_DEPRECATED
  FORCE_INCLUDE cstdint)

target_link_libraries(reactcommon_fabric PUBLIC reactcommon_core)
# core references Fabric symbols too (ReactInstance.cpp calls
# ShadowNode::setUseRuntimeShadowNodeReferenceUpdateOnThread), so declare the
# cycle and let CMake repeat the static libs on the link line.
target_link_libraries(reactcommon_core PUBLIC reactcommon_fabric)
