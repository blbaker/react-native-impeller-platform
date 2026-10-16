# 03 — Embedding, Platform Integration, Resources

Status: COMPLETE. Pinned Flutter SHA `114eb184d66d7ca136d89eb8ec09f61aff265062`. Permalink form:
`https://github.com/flutter/flutter/blob/114eb184d66d7ca136d89eb8ec09f61aff265062/<path>#L<a>-L<b>`

## 1. Platform backends and runtime selection

- **iOS/macOS**: Metal unconditionally. `IOSSurfaceMetalImpeller` wraps a `CAMetalLayer` and is
  valid iff an Impeller context + `AiksContext` exist — no fallback path
  [F:engine/src/flutter/shell/platform/darwin/ios/ios_surface_metal_impeller.mm:L18-L29]. Desktop
  mirror: `FlutterDarwinContextMetalImpeller.mm` exists alongside a parallel
  `FlutterDarwinContextMetalSkia.mm`, i.e. Skia is the only sibling backend, never GL/Vulkan
  [F:engine/src/flutter/shell/platform/darwin/graphics (file listing)].
- **Android**: Vulkan-first, OpenGL ES 2.0 fallback. Decision tree: device must support Vulkan,
  Android API ≥ 29 (Q), Vulkan ≥ 1.1, and required extensions (`VK_ANDROID_external_memory_...`
  for `HardwareBuffer`/platform-view interop); any failure drops to GLES
  [F:docs/engine/impeller/docs/android.md:L3-L68]. `AndroidRenderingAPI` enum carries
  `kImpellerOpenGLES` / `kImpellerVulkan` / `kImpellerAutoselect`
  [F:engine/src/flutter/shell/platform/android/android_rendering_selector.h:L10-L19].
  `AndroidContextVKImpeller` builds a `ContextVK`, and even after Vulkan 1.1 + extensions pass,
  rejects the context and falls back to GLES if `DriverInfoVK::IsKnownBadDriver()` is true
  [F:engine/src/flutter/shell/platform/android/android_context_vk_impeller.cc:L54-L71]. The deny
  list is a literal device/vendor blocklist: specific buggy Pixel 10 PowerVR driver versions,
  Adreno ≤ 650 (needs GL ES workarounds Vulkan lacks), all Huawei (Maleoon GPUs), and known-bad
  Samsung Xclipse — each with a tracking issue URL in the source comment
  [F:engine/src/flutter/impeller/renderer/backend/vulkan/driver_info_vk.cc:L377-L409].
  `AndroidSurfaceDynamicImpeller::SetupImpellerSurface` is the actual runtime switch: it reads
  `android_context_->RenderingApi()` and instantiates either `AndroidSurfaceVKImpeller` or
  `AndroidSurfaceGLImpeller`, with every other surface method (`CreateGPUSurface`, resize, resource
  context, snapshot) forwarding to whichever is non-null
  [F:engine/src/flutter/shell/platform/android/android_surface_dynamic_impeller.cc:L31-L119].
- **Windows**: GLES via ANGLE-over-D3D11 (confirmed by the study's starting facts and by the
  `shell/platform/windows/egl/*` directory wrapping `<EGL/egl.h>` directly, not raw D3D —
  `EGLErrorToString`/`LogEGLError` are the only abstraction over the platform GPU API
  [F:engine/src/flutter/shell/platform/windows/egl/egl.cc:L1-L68]; `WindowSurface` is an EGL
  surface with `eglSwapInterval` for vsync [F:engine/src/flutter/shell/platform/windows/egl/window_surface.cc:L13-L42]).
- **Linux (GTK embedder)**: GLES via EGL/libepoxy, native Mesa — `fl_compositor_opengl.cc` pulls in
  `<epoxy/egl.h>` and `<epoxy/gl.h>` directly and composites via a GL shader program, no ANGLE
  [F:engine/src/flutter/shell/platform/linux/fl_compositor_opengl.cc:L1-L35,L55-L84].
- **Generic embedder API**: `FlutterRendererConfig` is a tagged union of exactly four backend
  configs — `open_gl`, `software`, `metal`, `vulkan` — selected by `FlutterRendererType type`
  [F:engine/src/flutter/shell/platform/embedder/embedder.h:L1047-L1055]. Resize is driven by
  `FlutterWindowMetricsEvent` (adjacent struct) [F:engine/src/flutter/shell/platform/embedder/embedder.h:L1062-L1065].
  External-texture registration is also embedder-API surface, not backend-specific
  [F:engine/src/flutter/shell/platform/embedder/embedder.h:L3226-L3261].

## 2. Surface acquire/present, buffering, resize

- **iOS**: `GetCAMetalLayer` resizes `layer.drawableSize` to the requested frame size and forces
  `framebufferOnly = NO` because Flutter (backdrop filters, platform-view readback) must read the
  color attachment back — a real perf cost accepted deliberately
  [F:engine/src/flutter/shell/platform/darwin/ios/ios_surface_metal_impeller.mm:L54-L65]. The
  `PresentDrawable`/`GetMTLTexture`/`PresentTexture` delegate methods are dead `FML_CHECK(false)`
  paths on the Impeller surface — present actually happens through the CAMetalLayer-drawable path
  the GPU surface owns, not these [F:...ios_surface_metal_impeller.mm:L67-L91].
- **macOS**: `FlutterSurfaceManager` does pooled double buffering with IOSurface-backed `CALayer`
  content, not a classic swapchain. `surfaceForSize:` pulls a same-size surface from
  `FlutterBackBufferCache` or allocates a new one; `commit:` moves current front surfaces back into
  the cache, swaps in the new ones as CALayer `.contents`, and allocates one CALayer per surface +
  overlay sublayer per paint region (used for platform-view compositing, §9)
  [F:engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterSurfaceManager.mm:L103-L231].
  The cache purges by LRU-ish age (`kSurfaceEvictionAge = 30` frames) and idles out fully after
  `kIdleDelay = 1.0 s` of no activity [F:...FlutterSurfaceManager.mm:L285-L389] — i.e. buffer count
  is demand-driven, not fixed double/triple.
- **Resize without stretched/black frames (macOS)**: `ResizeSynchronizer` blocks the *platform*
  thread inside `beginResize(forSize:...)` (called from `NSView.setFrameSize:`) for up to 1 s,
  pumping the Flutter message queue, until the raster thread's `performCommit(forSize:...)` reports
  a frame matching the new target size — only then does the native resize complete, so the window
  never shows old-content-at-new-bounds or letterboxing; a timeout fires `onTimeout` instead of
  hanging forever [F:engine/src/flutter/shell/platform/darwin/macos/framework/Source/ResizeSynchronizer.swift:L8-L141;
  F:engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterView.mm:L76-L88].
- **Android GLES**: `OnScreenSurfaceResize` is a no-op — Impeller's GLES surface doesn't need
  resized auxiliary buffers the way iOS's older Skia path did
  [F:engine/src/flutter/shell/platform/android/android_surface_gl_impeller.cc:L120-L125]. The EGL
  context is explicitly cleared (`GLContextClearCurrent`) at the end of **every** frame as a
  driver-crash workaround for `eglMakeCurrent` races during activity transitions / platform-view
  rendering [F:...android_surface_gl_impeller.cc:L22-L28,L115-L117].
- **Vulkan swapchain resize / out-of-date**: `KHRSwapchainVK::AcquireNextDrawable` checks the
  swapchain's cached `size_` against the live surface; on an `out_of_date` acquire result it
  (outside Android) re-queries the OS-reported surface size, tears down and recreates the
  swapchain reusing the old `VkSurfaceKHR`, and retries — capped at `kMaxResizeAttempts = 3`, after
  which it gives up and returns `nullptr` rather than looping forever
  [F:engine/src/flutter/impeller/renderer/backend/vulkan/swapchain/khr/khr_swapchain_vk.cc:L48-L116].

## 3. App backgrounding (iOS GPU-quiescent requirement)

`FlutterEngine` on iOS registers for `UIApplicationDidEnterBackgroundNotification` /
`UIApplicationWillEnterForegroundNotification`
[F:engine/src/flutter/shell/platform/darwin/ios/framework/Source/FlutterEngine.mm:L310-L319] and
exposes `setIsGpuDisabled:`, which calls
`_shell->SetGpuAvailability(kUnavailable/kAvailable)`
[F:engine/src/flutter/shell/platform/darwin/ios/framework/Source/FlutterEngine.mm:L1476-L1481, L814-L819]. That `GpuAvailability` flag is read everywhere GPU
work can be deferred or must be skipped: image-texture upload
(`ImageDecoderImpeller::UploadTextureToPrivate` checks `gpu_disabled_switch` and either runs inline
or calls `context->StoreTaskForGPU(...)`, which **fails the upload outright** — "Image upload failed
due to loss of GPU access." — if the GPU stays unavailable
[F:engine/src/flutter/lib/ui/painting/image_decoder_impeller.cc:L584-L609]) and snapshot capture
(`SnapshotControllerImpeller::MakeImpellerSnapshot` does the identical `SyncSwitch` + `StoreTaskForGPU`
dance [F:engine/src/flutter/shell/common/snapshot_controller_impeller.cc:L135-L159]). This is the
actual mechanism: Flutter does **not** special-case "stop the raster thread," it gates every
GPU-submission call site on one shared switch so a backgrounded app submits zero GPU commands by
construction, not by convention.

## 4. Context/surface loss recovery

- **Vulkan `VK_ERROR_OUT_OF_DATE_KHR` / resize-implied loss**: handled by the retry-and-recreate
  loop in §2 [F:.../khr_swapchain_vk.cc:L48-L116]. `VK_ERROR_DEVICE_LOST` itself: **not confirmed**
  as a distinct recovery path — `grep -rn "DEVICE_LOST"` under
  `engine/src/flutter/impeller/renderer/backend/vulkan` returned no non-test hits; only
  `RecreateSwapchain`/`OUT_OF_DATE` paths exist in the files this pass read.
- **GLES `EGL_CONTEXT_LOST`**: Windows' `egl.cc` enumerates the error code in its logging table
  [F:engine/src/flutter/shell/platform/windows/egl/egl.cc:L46-L47] but a dedicated
  recreate-on-context-lost routine was **not confirmed**: `grep -n "EGL_CONTEXT_LOST|CONTEXT_LOST"
  egl/context.cc` returned 0 matches. Android's workaround (§2, clearing context every frame) is a
  crash-avoidance measure, not a loss-recovery path.

## 5. HDR / wide gamut

`enableWideGamut` is threaded end-to-end on Darwin: `FlutterView` takes it at init and exposes
`setEnableWideGamut:`, which forwards to `FlutterSurfaceManager setEnableWideGamut:`, which — if
the value actually changed — **flushes the entire back-buffer cache and clears front surfaces**
because existing surfaces have the wrong Metal pixel format
[F:engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterView.h:L76-L78;
F:...FlutterSurfaceManager.mm:L123-L135]. `commit:` additionally discards (returns early on) any
incoming surface batch whose `isWideGamut` doesn't match the current mode
[F:...FlutterSurfaceManager.mm:L171-L177]. On the decode side, `ImageDecoderImpeller` detects wide
gamut by computing the source color space's gamut triangle area against the sRGB baseline
(`kSrgbGamutArea = 0.0982f`) and, if wide and the context's capabilities support extended-range
formats, picks `kBGR_101010x_XR` (opaque, 4 bytes/px) or `kRGBA_F16` (has alpha, 8 bytes/px) instead
of 8888 [F:engine/src/flutter/lib/ui/painting/image_decoder_impeller.cc:L62-L77,L138-L153,L708-L716].
`IOSSurfaceMetalImpeller::CreateGPUSurface` re-reads the CAMetalLayer's actual `pixelFormat` into
the Impeller context on every surface creation, so a layer-format change (e.g. entering wide gamut)
propagates automatically [F:...ios_surface_metal_impeller.mm:L45-L51].

## 6. Embedder API (embedder.h)

`FlutterRendererConfig` (§1) is the entry point; each backend member
(`FlutterOpenGLRendererConfig`, `FlutterMetalRendererConfig`, `FlutterVulkanRendererConfig`,
`FlutterSoftwareRendererConfig`) is a struct of C function pointers the embedder fills in (make/
clear-current, present, fbo/texture callbacks, GL proc resolver, etc.)
[F:engine/src/flutter/shell/platform/embedder/embedder.h:L517-L1055]. External texture lifecycle is
three calls: `FlutterEngineRegisterExternalTexture`, `...UnregisterExternalTexture`,
`...MarkExternalTextureFrameAvailable` [F:...embedder.h:L3226-L3261] — the embedder owns the
texture's backing storage and only tells the engine "id N changed." Per-backend `EmbedderSurface*`
implementations (`embedder_surface_gl_impeller.cc`, `embedder_surface_vulkan.cc`,
`embedder_surface_vulkan_impeller.h`, `embedder_surface_metal_skia.mm`,
`embedder_surface_software.cc`) and an `embedder_external_view_embedder.cc` for platform-view
layering all live under `shell/platform/embedder/` — confirmed present by directory listing but not
read line-by-line this pass (budget).

## 7. IO thread, image decode, image cache

`ImageDecoderImpeller::Decode` posts decompression onto `concurrent_task_runner_` (a worker-pool
runner, never the UI or raster thread)
[F:engine/src/flutter/lib/ui/painting/image_decoder_impeller.cc:L670-L697]. Inside that task:
- **Target size clamp**: `target_size` is `min(max_texture_size, options.target_width/height)` —
  the decoder asks the *allocator* for `GetMaxTextureSizeSupported()` and never requests a texture
  bigger than that, compressed images are decoded at `get_scaled_dimensions()` of the ratio needed
  to hit that box [F:...image_decoder_impeller.cc:L226-L266,L347-L387,L708-L709].
- **Upload**: `UnsafeUploadTextureToPrivate` creates a `kDevicePrivate` texture, opens a
  `BlitPass`, `AddCopy`s the host buffer in, calls `GenerateMipmap` when `mip_count > 1`
  (`TextureDescriptor::MipCount()`), and — only if a CPU/GPU resize is still needed — blits again
  into a second texture via `BlitPass::ResizeTexture` with its own mip generation
  [F:...image_decoder_impeller.cc:L452-L535].
- **Threading nuance**: GLES uploads are explicitly routed onto the IO task runner because "I/O
  image uploads are not threadsafe on GLES"; Metal/Vulkan upload inline on the concurrent-runner
  thread that decoded them [F:...image_decoder_impeller.cc:L731-L737].
- **Fence/sync**: the command buffer is submitted, then the decoder either adds a tracking fence
  and only waits-until-scheduled, or (no fence support) blocks until fully completed, before
  disposing thread-local cached resources [F:...image_decoder_impeller.cc:L536-L560].
- **Android image cache sizing**: a fixed-size LRU array, `kImageReaderSwapchainSize = 6`,
  deliberately larger than a typical `ImageReader`'s own swapchain depth so hardware-buffer-backed
  frames aren't evicted and re-decoded needlessly
  [F:engine/src/flutter/shell/platform/android/image_lru.h:L15-L52].

## 8. External textures / texture registry

`TextureLayer::Paint` is backend-agnostic: it looks the texture up by id in
`context.texture_registry`, and if found calls `Texture::Paint(ctx, bounds, freeze, sampling)`
[F:engine/src/flutter/flow/layers/texture_layer.cc:L48-L66] — the registry indirection is what lets
each platform plug in its own texture representation. Per-platform realizations:
- **iOS/macOS**: `FlutterDarwinExternalTextureMetal` wraps a `CVPixelBufferRef` through a
  `CVMetalTextureCacheRef`, converts to a `DlImage`, and re-samples it every paint unless `freeze`
  is set [F:engine/src/flutter/shell/platform/darwin/graphics/FlutterDarwinExternalTextureMetal.mm:L30-L80].
- **Windows**: `ExternalTextureD3d` round-trips a D3D GPU surface through an embedder-supplied
  `FlutterDesktopGpuSurfaceDescriptor` callback into a GL texture via EGL image binding, releasing
  the EGL surface each frame (`eglReleaseTexImage`/`eglDestroySurface`) before rebinding
  [F:engine/src/flutter/shell/platform/windows/external_texture_d3d.cc:L12-L80].
- **Android**: `SurfaceTexture`/`HardwareBuffer`-registered external textures work on both backends
  for plain video/camera frames, but Vulkan **cannot** render GL-`SurfaceTexture`-backed external
  textures at all — that needs GL→Vulkan texture import the engine doesn't implement, so apps using
  `TextureRegistry.registerSurfaceTexture` force a GLES-path dependency
  [F:docs/engine/impeller/docs/android.md:L76-L90].

## 9. Platform views (hybrid composition)

`embedded_views.h` defines the mutator stack (`MutatorType::kClipRect/kClipPath/kTransform/
kOpacity/kBackdropFilter/...`) that Flutter replays around a platform view so clips/transforms/
filters applied by surrounding Flutter widgets still apply to the embedded native view
[F:engine/src/flutter/flow/embedded_views.h:L35-L47]. On macOS the actual compositing mechanism is
the same `FlutterSurfaceManager` overlay-sublayer system used for resize: for each paint-region
rectangle beyond the first, a dedicated `CALayer` is created/reused and its `contentsRect` is set to
the matching slice of the IOSurface, with optional colored debug borders per layer
(`FLTEnableSurfaceDebugInfo`) [F:...FlutterSurfaceManager.mm:L62-L101,L188-L217]. On Android,
platform views are supported on **both** GLES and Vulkan and are engine-managed, but require API 29
(`HardwareBuffer`) for efficient interop — pre-29 devices get the (slower) pre-HardwareBuffer path
implicitly by being forced onto GLES anyway (§1) [F:docs/engine/impeller/docs/android.md:L52-L74].

## 10. Snapshots / toImage

`SnapshotControllerImpeller::MakeImpellerSnapshot` renders the `DisplayList` to an
`impeller::Texture` at a size clamped the same way as image decode — scaled down by
`min(1.0, max_w/w, max_h/h)` against `GetMaxTextureSizeSupported()` so a snapshot request can never
exceed the GPU's texture limit — then calls `impeller::DisplayListToTexture` with
`generate_mips=true` [F:engine/src/flutter/shell/common/snapshot_controller_impeller.cc:L22-L67].
The GPU-disabled `SyncSwitch` gates this exactly like image upload (§3): if the GPU is unavailable
the render is deferred via `StoreTaskForGPU` (or silently dropped — `callback(nullptr)` — if there's
no `AiksContext`) rather than run against the backgrounded GPU
[F:...snapshot_controller_impeller.cc:L130-L159]. There is no Skia-image snapshot path in an
Impeller build: `MakeSkiaSnapshot`/`MakeSkiaSnapshotSync`/`MakeSkiaTextureImage` are
`FML_UNREACHABLE()` / return `nullptr` [F:...snapshot_controller_impeller.cc:L115-L128,L170-L174].

## 11. Memory pressure + shader/pipeline warmup

`Shell::NotifyLowMemoryWarning` always posts to the raster task runner and calls
`Rasterizer::NotifyLowMemoryWarning`
[F:engine/src/flutter/shell/common/shell.cc:L750-L767]. That rasterizer method's actual cache-purge
body — `context->performDeferredCleanup(0ms)` on the `GrDirectContext` — is wrapped in
`#if !SLIMPELLER` [F:engine/src/flutter/shell/common/rasterizer.cc:L173-L192]: `SLIMPELLER` is the
Impeller-only/Skia-stripped build flag, meaning **in a pure-Impeller build this specific GrContext
purge is compiled out**, and no Impeller-side equivalent purge was found in the same function body
— confirmed by reading the full function (lines 171-192 are the entire method). iOS separately
forwards low-memory to the Dart `SystemChannel` as a `memoryPressure` message regardless of backend
[F:engine/src/flutter/shell/platform/darwin/ios/framework/Source/FlutterEngine.mm:L1027-L1033], so
the Dart-level listeners (image cache eviction, etc.) still fire even when the native GPU-cache
purge doesn't apply. **Shader/pipeline warmup at startup**: not confirmed — `grep -rn
"PipelineCreationWarmup|WarmUpPipeline|shader.?warm"` under `engine/src/flutter/impeller` returned 0
hits; the only adjacent concept found is `Context::GetRuntimeStageBackend()`, which selects a
runtime-effect shader variant, not a warmup mechanism
[F:engine/src/flutter/impeller/renderer/context.h:L276].

## 12. RN-way mapping

| Flutter concept | RN 0.86 analogue | Note |
|---|---|---|
| `IOSSurfaceMetalImpeller` / `FlutterSurfaceManager` (surface + present) | No RN equivalent — RN's UIKit/Android-view host has no single "GPU surface" abstraction; the New-Architecture host surface is engine-specific (our `*Surface.cpp`, §13) | — |
| `ImageDecoder`/`ImageDecoderImpeller` (decode worker + IO-thread upload) | `ImageManager::requestImage` + `ImageRequest`/`ImageResponseObserverCoordinator` in `react/renderer/imagemanager` — RN's contract is "return an `ImageRequest`, complete it async," it says nothing about *which* thread decodes or *how* upload happens [RN:ReactCommon/react/renderer/imagemanager/ImageManager.h; RN:ReactCommon/react/renderer/imagemanager/ImageRequest.h] | the thread/clamp/mip policy is entirely host-defined |
| `TextureLayer` + `TextureRegistry` (external texture) | No first-class RN Fabric concept; closest is a native host component that owns its own GPU resource (video surface, camera preview) | our engine has nothing here (§13) |
| `embedded_views.h` mutator stack + platform-view overlay compositing | RN's "native component view" story — any component needing a *real* OS view (`WebView`, native video player) is the RN analogue of a Flutter platform view; RN's own `ViewProps`/`HostPlatformViewProps` only describe a view's styling, not embedding a foreign native surface [RN:ReactCommon/react/renderer/components/view/ViewProps.h:L10-L13; RN:ReactCommon/react/renderer/components/view/platform/cxx/react/renderer/components/view/HostPlatformViewTraitsInitializer.h:L13-L30] | `HostPlatformView*` here is RN's per-platform *prop/trait* customization point, not a platform-view embedding mechanism — do not conflate the two |
| `SnapshotControllerImpeller` (toImage) | RN has no engine-level "snapshot a subtree to texture" primitive; `ViewShadowNode`/Fabric has no analogue | gap is total (§13) |
| `Shell::SetGpuAvailability` (backgrounding) | RN's `AppState`/`Appearance`/`AccessibilityInfo` JS modules report lifecycle to JS; they do **not** gate native GPU submission — that gate has to be built at the host-surface layer, mirroring Flutter's `SyncSwitch` pattern | no RN source to cite — this is purely a host responsibility |

## 13. Our engine today (measured)

- **Surfaces**: four peers — `GlfwSurface` (desktop GL; on macOS reached through ANGLE, not system
  EGL, per the file's own `⛔` comment block, because Apple ships no EGL/GLES at all)
  [R:engine/host/GlfwSurface.cpp:L12-L56], `HeadlessSurface` (`ImpellerSurfaceCreateWrappedFBONew`)
  [R:engine/host/HeadlessSurface.cpp:L219-L221], `WinGLSurface`, and `AndroidVkSurface` (Vulkan,
  `libvulkan.so` loaded via `dlopen` + `vkGetInstanceProcAddr`, never link-time, so a
  Vulkan-less device fails only this one surface) [R:engine/host/AndroidVkSurface.cpp:L1-L98,
  R:engine/host/AndroidVkSurface.h:L1-L80]. There is **no OpenGL-ES-fallback path on Android at
  all** — `AndroidVkSurface` is the only Android surface class in the tree (confirmed:
  `grep -rn AndroidVkSurface` under `engine/` returns only its own file and `AndroidJni.cpp`), in
  contrast to Flutter's mandatory Vulkan→GLES fallback (§1).
- **Threading**: confirmed one thread does event-poll + display-list build + GPU submit + present;
  `paintFrame` builds a fresh `ImpellerDisplayListBuilder`, walks the whole `SceneGraph`, submits,
  optionally reads pixels for `--screenshot`, then presents — all inline, no raster-thread handoff
  [R:engine/host/main.cpp:L621-L659].
- **Resize**: `applyResizeIfDirty` + `surface.setRefreshHandler` drive repaint on both the normal
  frame-loop path and the AppKit modal-drag refresh-callback path, explicitly sharing one
  "paint-in-flight" scope so a reentrant refresh callback during `present()` is dropped instead of
  double-painting [R:engine/host/main.cpp:L600-L630,L688-L781,L1105-L1138]. This guards against a
  double-paint race but is **not** a macOS-Flutter-style "block until the frame committed at the new
  size" synchronizer (§2) — nothing in this loop blocks the platform/window thread until a
  matching-size frame presents, so a resize can still show one or more frames at the old content
  size inside new window bounds before the next paint catches up.
- **Android path is a smoke test, not a real frame loop**: the only JNI entry point driving
  `AndroidVkSurface` is `nativeDrawTestFrame`, which calls `AcquireNext()`, and on `nullptr` simply
  returns `JNI_FALSE` — there is **no** retry/recreate-swapchain logic anywhere in
  `AndroidVkSurface` or its JNI caller (confirmed: `AndroidVkSurface.h`'s own doc comment says
  "returns nullptr when the swapchain is out of date (**the caller should re-attach**)," but no
  caller does) [R:engine/host/AndroidJni.cpp:L98-L112; R:engine/host/AndroidVkSurface.h:L61-L65].
  Contrast directly with Flutter's 3-retry `KHRSwapchainVK::AcquireNextDrawable` (§2).
- **Backgrounding / GPU availability**: not implemented. `grep -n
  "GpuAvailability|isBackground|onPause|onResume|applicationDidEnterBackground|SIGSTOP"` under
  `engine/host` returns 0 matches. There is no equivalent of Flutter's `SyncSwitch`
  gate anywhere in the engine.
- **Images**: `rni::image::LoadAsync` decodes with `stb_image` on a **detached** `std::thread` per
  unique in-flight URI (de-duplicated via a `gPending` waiter-list map, so N widgets requesting the
  same URL share one decode) [R:engine/fabric/ImageStore.cpp:L137-L230]. Critically: `Decode()`
  takes no target size and never clamps to a max texture size — a 40 MP source photo decodes (and
  is RGBA-expanded: 4×) at full resolution before upload, with no GPU-side blit/resize/mip step at
  all [R:engine/fabric/ImageStore.cpp:L82-L100]. Alpha premultiplication is a plain scalar
  byte-at-a-time loop, not SIMD or GPU-side [R:engine/fabric/ImageStore.cpp:L94-L98].
  `ImageManager::requestImage` is RN's Fabric hook wired straight to this store: local URIs (data:,
  file://, absolute path) decode synchronously inline at commit time, remote URIs complete later via
  the fetch worker and the image-response observer coordinator
  [R:engine/fabric/platform/impeller/react/renderer/imagemanager/ImageManager.cpp:L17-L44].
- **External textures, platform views, snapshot/toImage**: none exist. `grep -rn
  "PlatformView|ExternalTexture|TextureRegistry|toImage|MakeSnapshot|takeSnapshot"` under `engine/`
  returns only unrelated RN-codegen `HostPlatformViewProps::getDiffProps` boilerplate calls in
  generated SVG prop files, not an actual embedding/texture/snapshot mechanism
  [R:engine/svg/generated/react/renderer/components/rnsvg/Props.cpp:L87 (representative hit)].
  `WorldRasterStore`, named in this task's brief as a CPU-uploaded-texture store, does **not exist**
  in the tree — `grep -rn WorldRasterStore` finds nothing; treat that name as unconfirmed/stale.

## 14. Gaps, ranked by risk

1. **Crash/frozen-frame — Android swapchain OUT_OF_DATE is never recovered.** A rotation, a
   multi-window resize, or any `VK_ERROR_OUT_OF_DATE_KHR` makes `AcquireNext()` return `nullptr`
   forever; nothing re-attaches or recreates the swapchain. On a real (non-smoke-test) Android app
   this is an unrecoverable black/frozen screen after the first resize.
2. **Memory/crash — unbounded image decode size.** No target-size clamp, no max-texture-size clamp,
   no downsample. A 40 MP photo (or a malicious oversized image) allocates 4×40 MB+ RGBA on a
   detached thread with no backpressure and can exceed GPU max texture dimensions outright, failing
   texture upload with no fallback.
3. **Correctness/visual — GPU work continues while backgrounded (iOS).** No `SyncSwitch`-equivalent
   anywhere; Impeller submit/present would happily keep running in the background on iOS, which
   Apple can and does kill the process for.
4. **Visual — resize can show stale-content-in-new-bounds.** No commit-size synchronizer; a fast
   resize can present 1+ frames of old-size content before the matching frame lands, unlike macOS
   Flutter's blocking `ResizeSynchronizer`.
5. **Jank/stutter — no backend fallback path on any platform.** Every surface is hard-pinned to one
   backend (GL desktop / Vulkan Android); a known-bad GPU driver (exactly the case Flutter's
   `IsKnownBadDriver()` deny-list exists for) has no fallback and simply fails to render.
6. **Feature gap — no platform views, no external textures, no toImage/snapshot.** Any RN app using
   `WebView`, a native video surface, `react-native-view-shot`-style snapshotting, or a
   camera/video `TextureRegistry`-style component cannot be hosted at all.
7. **Resource leak risk — memory-pressure purge is a no-op path in practice.** Even Flutter's own
   Impeller-build purge is compiled out (`SLIMPELLER`); our engine has nothing resembling it, so
   there's no bound on retained GPU/CPU image memory under system memory pressure.

## 15. Work items

1. **Recreate the Android Vulkan swapchain on OUT_OF_DATE.**
   Build: in `AndroidVkSurface`, on `AcquireNext()` returning `nullptr`, tear down and recreate the
   swapchain against the current `ANativeWindow` size (mirror `DetachWindow`+`AttachWindow`), retry
   bounded (e.g. 3x) before surfacing a hard failure.
   Model: `KHRSwapchainVK::AcquireNextDrawable`'s resize-retry loop
   [F:.../khr_swapchain_vk.cc:L48-L116].
   Gate: rotate/resize the Android test activity's window 20x in a loop; assert zero frozen frames
   and `AcquireNext()` eventually returns non-null again each time.
   Mutant: delete the recreate call (leave only the `nullptr` early-return) — gate must go from
   pass to fail/timeout.

2. **Clamp image decode to a target box + max texture size, resize on CPU or via Impeller blit.**
   Build: thread `target_width`/`target_height` (from the RN `<Image>` layout size) and
   `GetMaxTextureSizeSupported()`-equivalent into `rni::image::LoadAsync`; downsample before
   upload.
   Model: `ImageDecoderImpeller::DecompressTexture` + `ResizeOnCpu` / `BlitPass::ResizeTexture`
   [F:lib/ui/painting/image_decoder_impeller.cc:L226-L266,L452-L534].
   Gate: decode a 8000×6000 synthetic PNG requested into a 200×200 `<Image>`; assert peak RSS stays
   under a fixed budget (e.g. 50 MB) and the uploaded texture's dimensions are ≤ the clamp box.
   Mutant: skip the clamp (upload at native size) — gate's RSS/dimension assertion must fail.

3. **Gate all GPU submission on an app-lifecycle switch (iOS/Android background).**
   Build: a `GpuAvailability`-style atomic flag flipped by the host's background/foreground
   lifecycle callbacks; `paintFrame` and any texture-upload/snapshot path check it before touching
   the GPU context.
   Model: `Shell::SetGpuAvailability` + the `fml::SyncSwitch` checks in
   `ImageDecoderImpeller::UploadTextureToPrivate` and `SnapshotControllerImpeller::MakeImpellerSnapshot`
   [F:lib/ui/painting/image_decoder_impeller.cc:L584-L609; F:shell/common/snapshot_controller_impeller.cc:L135-L159].
   Gate: simulate backgrounding mid-frame-loop (iOS harness or a host-side fake); assert zero GPU
   submit/present calls occur between the background signal and the foreground signal (instrument
   with a call counter around `surface.present()`).
   Mutant: forget to check the flag inside the paint loop — gate's zero-GPU-calls assertion fails.

4. **Block the resize caller until a matching-size frame presents.**
   Build: a `ResizeSynchronizer`-equivalent: the platform/window thread blocks (pumping JS-thread
   messages, not the GPU loop) after a resize event until `paintFrame` presents at the new size, or
   a timeout fires.
   Model: `ResizeSynchronizer.beginResize`/`performCommit`
   [F:.../ResizeSynchronizer.swift:L73-L141].
   Gate: resize the window rapidly across 10 random sizes; screenshot immediately after each native
   resize call returns; assert every screenshot's content size matches the new window size (no
   stale-content frame).
   Mutant: remove the blocking wait (resize returns immediately) — gate must catch at least one
   stale-size screenshot.

5. **Add a GPU-driver deny-list with GL fallback, or at minimum fail loud+recoverably.**
   Build: on Android, before committing to Vulkan, check a small deny-list (reuse Flutter's known
   entries as a seed) and fall back to a GLES surface path (which does not exist today — this is a
   larger build item: port `AndroidSurfaceGLImpeller`-equivalent).
   Model: `DriverInfoVK::IsKnownBadDriver` [F:.../driver_info_vk.cc:L377-L409] +
   `AndroidSurfaceDynamicImpeller` dispatch [F:.../android_surface_dynamic_impeller.cc:L31-L59].
   Gate: force the deny-list check to return true in a test build; assert the engine still produces
   frames (via the GL path) instead of failing to initialize.
   Mutant: force deny-list true but skip the fallback wiring — gate must fail (no frames / init
   error).

6. **Build a texture-registry + platform-view primitive before any WebView/video RN component can land.**
   Build: a `TextureRegistry`-equivalent keyed by id, a `TextureLayer`-equivalent paint call, and a
   mutator-stack-equivalent (clip/transform/opacity) wrapped around any embedded native surface.
   Model: `flow/layers/texture_layer.cc` + `flow/embedded_views.h`
   [F:flow/layers/texture_layer.cc:L48-L66; F:flow/embedded_views.h:L35-L47].
   Gate: register a solid-color test texture by id, paint a tree referencing it inside a clipped +
   rotated container; assert the rendered pixels show the color clipped/rotated as specified.
   Mutant: skip applying the mutator stack around the texture — gate's clip/rotation pixel check
   must fail.

7. **Add a bounded image-memory purge under low-memory pressure.**
   Build: an LRU-bounded image cache (reuse the clamp from item 2) with an explicit
   `NotifyLowMemoryWarning`-equivalent hook that evicts.
   Model: Android's fixed-size `ImageLRU` [F:shell/platform/android/image_lru.h:L15-L52] (note: this
   is the pattern to copy — Flutter's own engine-level Impeller purge is itself a known gap, §14.7).
   Gate: load N images past the cache bound, send the low-memory signal, assert cache size drops to
   the configured floor and least-recently-used entries are gone.
   Mutant: make the low-memory hook a no-op — gate's post-signal size assertion must fail.
