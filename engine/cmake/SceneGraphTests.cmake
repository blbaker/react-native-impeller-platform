# FP-50: rni-scenegraph-tests, the fast layer under the ci-* gates (Flutter's TEST_P layer):
# canned mutation lists -> the real SceneGraph painter -> a text log of every Impeller builder call
# (scenegraph/DrawOpLog). No GPU, no Hermes, no JS. Built with the engine (ninja builds every target),
# run by CTest (`ctest --test-dir engine/build`) and by tools/ci-unit.sh.
if(NOT WIN32 AND NOT ANDROID)
  add_executable(rni-scenegraph-tests
    tests/TestMain.cpp
    tests/SceneFixture.cpp
    tests/CasesBox.cpp
    tests/CasesEffects.cpp
    tests/CasesClipTransform.cpp
    tests/CasesContent.cpp
    fuzz/FuzzFabric.cpp
    fabric/ComponentRegistry.cpp
    fabric/ExpoBlurShadowNode.cpp
    fabric/platform/impeller/PlatformColorTable.cpp
    scenegraph/SceneGraph.cpp
    scenegraph/SceneGraphContextLoss.cpp
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
    scenegraph/DamageTracker.cpp
    scenegraph/IoUploaderGl.cpp
    scenegraph/ImageEvents.cpp
    scenegraph/TextInputStyle.cpp
    scenegraph/ColorMatrixFilter.cpp
    scenegraph/ContentFilters.cpp
    scenegraph/BackdropBlur.cpp
    scenegraph/BlendGroup.cpp
    scenegraph/EllipsizeText.cpp
    scenegraph/ParagraphCache.cpp
    scenegraph/BorderCurve.cpp
    scenegraph/BorderDashRounded.cpp
    scenegraph/DrawOpLog.cpp
    scenegraph/DrawOpHooks.cpp
    scenegraph/DrawOpHooksObjects.cpp
    scenegraph/TextureRegistry.cpp  # FP-42/43/44 (lane A), linked by SceneGraph.cpp
    scenegraph/ExternalTexturePaint.cpp
    scenegraph/PlatformViewRecord.cpp
    scenegraph/SnapshotController.cpp
    scenegraph/SnapshotRecord.cpp
    scenegraph/ImageEncode.cpp
    scenegraph/SnapshotReadbackGl.cpp
    text/ImpellerTextLayoutManager.cpp
    text/FontRegistry.cpp
    text/TypographyContexts.cpp
    text/FontFamily.cpp
    text/FontFallback.cpp
    base/Trace.cpp
    base/ProgramCount.cpp
    base/GlLimits.cpp
    base/GpuAvailability.cpp
    base/TestSync.cpp)  # FP-57: ImageEvents.cpp test probe
  target_include_directories(rni-scenegraph-tests PRIVATE ${CMAKE_SOURCE_DIR} "${IMPELLER_SDK}/include"
    "${RN_ROOT}/React" "${RN_ROOT}/React/FBReactNativeSpec")
  rni_compile_flags(rni-scenegraph-tests EXCEPTIONS RTTI NO_DEPRECATED FORCE_INCLUDE cstdint)
  target_link_libraries(rni-scenegraph-tests PRIVATE reactcommon_fabric reactcommon_core rc_ssl
    "${IMPELLER_LINK_LIB}")
  if(RNI_WITH_RNSVG)
    target_compile_definitions(rni-scenegraph-tests PRIVATE RNI_WITH_RNSVG=1)
    target_link_libraries(rni-scenegraph-tests PRIVATE rnsvg_common)
  endif()
  if(APPLE)
    target_include_directories(rni-scenegraph-tests SYSTEM PRIVATE "${CMAKE_SOURCE_DIR}/third_party/khronos")
    target_link_libraries(rni-scenegraph-tests PRIVATE "${ANGLE_DIR}/libEGL.dylib" "${ANGLE_DIR}/libGLESv2.dylib"
      "-framework CoreFoundation" "-framework CoreText" "-framework Foundation")
  else()
    target_link_libraries(rni-scenegraph-tests PRIVATE EGL GLESv2)
  endif()
  set_target_properties(rni-scenegraph-tests PROPERTIES BUILD_RPATH "${HERMES_BUILD}/lib;${IMPELLER_SDK}/lib;${ANGLE_DIR}")
  enable_testing()
  add_test(NAME rni-scenegraph-tests COMMAND rni-scenegraph-tests)
endif()
