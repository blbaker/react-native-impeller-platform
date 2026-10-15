# react-native-impeller: rendering architecture to Flutter parity

Research and build spec. 2026-10-14. Status: PROPOSED, waiting for Baker's approval. Nothing below is built yet.

Scope: how Flutter uses Impeller for every part of rendering, read from Flutter's own source. Then how to follow that design inside a React Native 0.86 host (Hermes + Fabric + TurboModules), what our engine does today, and the ordered work to close the gap. Each work item comes with a gate, plus a mutant the gate has to catch.

Sources and how to read the citations:

- `[F:path:Lx-Ly]` = flutter/flutter at `114eb184d66d` (2026-08-09). That is the exact commit our custom Impeller SDK is built from (`engine/IMPELLER_SHA`). Read from a full local checkout and linked to GitHub.
- `[R:path:Lx]` = our engine, `blbaker/react-native-impeller` at `c07048d` (feat/native-anim-transform).
- `[RN:path:Lx]` = React Native 0.86.2 source as vendored in our tree.
- Audit: 335 citations (spec + appendices) were machine-checked (each file exists at the pinned commit and the line range is in bounds). I also re-read 22 load-bearing claims against the source by hand. One line number had drifted by 4 lines and is fixed. Appendices A-D hold the full per-subsystem research, about 1,650 lines.
- Flutter master (`200fdfbd`, 2026-10-14) has the same Impeller C API as our pin: 176 functions, none added or removed. Bumping the pin buys renderer fixes, not new API.

## 1. TL;DR: the five findings that set the plan

1. **Flutter never renders on the main thread. We render everything there.** Flutter runs four task runners: platform, UI, raster and IO. On iOS, Android, macOS and Windows, UI, raster and IO each get a dedicated thread [F:docs/about/The-Engine-architecture.md:L282-L311]. Only Linux shares platform and raster [F:docs/about/The-Engine-architecture.md:L312-L316]. Our main thread polls events, walks the whole tree, builds the display list, submits to the GPU and presents [R:engine/host/main.cpp:L621-L662]. Fabric commits contend with that walk on one mutex [R:engine/scenegraph/SceneGraph.cpp:L1149-L1151].
2. **Our "native-driven" animations aren't native-driven yet.** In RN, NativeAnimated ticks on the UI thread from a platform frame callback: CADisplayLink on iOS [RN:Libraries/NativeAnimation/RCTNativeAnimatedNodesManager.mm:L443-L463] and the C++ manager's "UI tick listener" [RN:ReactCommon/react/renderer/animated/NativeAnimatedNodesManager.cpp:L519-L520]. Ours queues every tick behind all other JS work [R:engine/runtime/ReactHost.cpp:L485-L505]. A busy JS thread stalls the animation, which is exactly what the native driver exists to prevent.
3. **On Apple, Flutter renders with Metal directly. We go through ANGLE.** iOS/macOS = Metal only [F:engine/src/flutter/shell/platform/darwin/ios/ios_surface_metal_impeller.mm:L18-L29]. Android = Vulkan first, then GLES, with a list of known-bad drivers [F:engine/src/flutter/shell/platform/android/android_context_vk_impeller.cc:L54-L71]. Windows = GLES on ANGLE-D3D11 [F:engine/src/flutter/shell/platform/windows/egl/manager.cc:L69-L69], the same as ours. Linux = GLES only [F:engine/src/flutter/shell/platform/linux/fl_engine.cc:L786-L792], also the same. **Only darwin diverges**: we run GLES → ANGLE → Metal.
4. **Native Metal gets anti-aliasing for free; the GL path never gets it.** Impeller's Metal drawable wrap renders into a 4x MSAA texture and resolves it into the drawable [F:engine/src/flutter/impeller/renderer/backend/metal/surface_mtl.mm:L82-L87; F:engine/src/flutter/impeller/renderer/backend/metal/swapchain_transients_mtl.mm:L54-L54]. The GL wrap is hard-coded to 1 sample [F:engine/src/flutter/impeller/renderer/backend/gles/surface_gles.cc:L33-L33]. Flutter's own desktop-GL path uses that same 1x wrap [F:engine/src/flutter/shell/gpu/gpu_surface_gl_impeller.cc:L93-L93]. So on Win/Linux our supersample hook goes beyond what Flutter does, and on darwin it can be retired once the switch to native Metal lands.
5. **The SDK hides two of Impeller's quality features, and we can patch both back in.** The C API builds every context with default `Flags{}` [F:engine/src/flutter/impeller/toolkit/interop/backend/metal/context_mtl.mm:L31-L31; F:engine/src/flutter/impeller/toolkit/interop/backend/gles/context_gles.cc:L31-L31; F:engine/src/flutter/impeller/toolkit/interop/backend/vulkan/context_vk.cc:L55-L55], so analytic SDF anti-aliasing for circles and rounded rects (`use_sdfs`, default false [F:engine/src/flutter/impeller/base/flags.h:L9-L11]) is unreachable. We already build the SDK from source with two patches, so a third patch can expose it. Prebuilt-SDK users can't do this.

## 2. Flutter's design, translated to the RN way

"Strictly, but in an RN way" means: keep Flutter's thread roles, frame pipeline, backend choices and quality bar, and keep RN's contracts unchanged. Those contracts are: JS owns React, Fabric commits immutable shadow-tree revisions, mounting happens on the main thread, and NativeAnimated runs off the JS thread.

| Flutter role | Flutter mechanism | Our RN-way equivalent | Today |
|---|---|---|---|
| UI thread (Dart) | builds the layer tree, never given native work [F:docs/about/The-Engine-architecture.md:L148-L198] | JS thread: Hermes, React, Fabric commit | correct |
| Hand-off | immutable `LayerTree` through `Pipeline<T>`, depth 2 (1 when platform == raster) [F:engine/src/flutter/shell/common/animator.cc:L32-L41] | immutable shadow-tree revision → `MountingTransaction` [RN:ReactCommon/react/renderer/mounting/MountingCoordinator.h:L26-L32] → our frozen render-tree snapshot, depth 2 | live tree + mutex |
| Frame scheduling | `Animator::RequestFrame` → `VsyncWaiter` → `BeginFrame` | `FrameScheduler`: requests come from mount, NativeAnimated, caret, resize; per-OS vsync | repaint every swap, no explicit vsync |
| Vsync source | CVDisplayLink (macOS), CADisplayLink (iOS), Choreographer (Android) [F:engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterDisplayLink.mm:L42-L64; F:engine/src/flutter/shell/platform/android/vsync_waiter_android.cc:L31-L38] | the same per OS; DWM/swap interval on Windows, swap interval on Linux | none (`SwapInterval`: 0 hits) |
| Raster thread | `Rasterizer::Draw`: display list → `impeller::Canvas` → present [F:engine/src/flutter/impeller/display_list/dl_dispatcher.cc:L1309-L1337] | raster thread: snapshot → `ImpellerDisplayList` → surface → present | on the main thread |
| Animation tick | Dart animations on vsync | NativeAnimated `onRender` on the platform/UI thread at vsync (RN's own contract, above) | JS FIFO |
| IO thread | decode, resize to target and upload off raster; clamped to max texture size [F:engine/src/flutter/lib/ui/painting/image_decoder_impeller.cc:L226-L232; F:engine/src/flutter/lib/ui/painting/image_decoder_impeller.cc:L709-L709] | IO pool: decode + resize to the `<Image>` box + texture upload | 1 detached thread per image, no clamp, upload on paint [R:engine/fabric/ImageStore.cpp:L219-L230] |
| Raster cache | hard OFF under Impeller [F:engine/src/flutter/shell/gpu/gpu_surface_metal_impeller.mm:L371-L374; F:engine/src/flutter/shell/common/rasterizer.cc:L807-L810] | do NOT build one | none (correct) |
| Partial repaint | damage clip only when the dirty rect is at most 70% of a side [F:engine/src/flutter/flow/compositor_context.cc:L183-L224] | dirty-rect clip from the snapshot diff, same 0.7 rule | full repaint or idle-skip |
| Resize | macOS blocks the platform thread until a frame at the new size commits (1 s cap) [F:engine/src/flutter/shell/platform/darwin/macos/framework/Source/ResizeSynchronizer.swift:L75-L113]; a frame for a stale size is thrown away [F:engine/src/flutter/shell/common/shell.cc:L1860-L1866] | same synchronizer + discard guard | re-entrancy guard only |
| Background | one `GpuAvailability` switch checked before all GPU work [F:engine/src/flutter/shell/platform/darwin/ios/framework/Source/FlutterEngine.mm:L1476-L1481] | same switch, driven by RN AppState/lifecycle | none |
| Declarative layout anim | n/a (Dart) | `UIManagerAnimationDelegate` [RN:ReactCommon/react/renderer/uimanager/UIManagerAnimationDelegate.h:L16-L43] | `nullptr`, so LayoutAnimation snaps instantly [R:engine/fabric/FabricHost.cpp:L679-L680] |
| Frame timing | FrameTiming build/raster stamps → DevTools | RN's own `FrameTimingSequence` [RN:ReactCommon/jsinspector-modern/tracing/FrameTimingSequence.h:L25-L26] + PerformanceObserver, fed by our recorder | printf lines |

**Thread rules for the target design** (from the interop SDK's own contracts):

- All Impeller objects are thread-safe ref-counted, but not every object can be used from many threads at once [F:engine/src/flutter/impeller/toolkit/interop/README.md:L106-L117].
- Typography contexts are single-thread: create, use and free them on one thread [F:engine/src/flutter/impeller/toolkit/interop/impeller.h:L220-L221]. So paragraph build and measure move with the raster thread, or each thread gets its own context.
- Textures should be created on background threads, with a GL caveat [F:engine/src/flutter/impeller/toolkit/interop/impeller.h:L299-L303]. That gives Metal/Vulkan a clean IO upload; on GL it needs a shared resource context, which is Flutter's IO design [F:docs/about/The-Engine-architecture.md:L228-L262].
- Vulkan adds its own internal worker pool plus fence-waiter and resource-manager threads [F:docs/engine/impeller/docs/vulkan_threading.md:L1-L20]. Budget for them; don't fight them.

## 3. Backend matrix (Flutter parity)

| OS | Flutter today | Ours today | Target |
|---|---|---|---|
| macOS / iOS | Metal | GLES → ANGLE → Metal | **native Metal** windowed. Headless gates stay on GL: the C API's only offscreen surface is a wrapped GL FBO [R:engine/host/WinGLSurface.cpp:L20-L25], until patch 0004 adds a Metal texture surface |
| Android | Vulkan → GLES fallback + bad-driver list | Vulkan, render-only AAR, no fallback | Vulkan + GLES fallback + Flutter's bad-driver list [F:engine/src/flutter/impeller/renderer/backend/vulkan/driver_info_vk.cc:L377-L409] |
| Windows | GLES / ANGLE-D3D11 | GLES / ANGLE-D3D11 | keep (parity) |
| Linux | GLES / EGL | GLES / EGL (llvmpipe in CI) | keep (parity) |

Anti-aliasing per backend, after the plan: Metal and Vulkan get 4x MSAA from the surface wrap. GL keeps our whole-tree supersample hook, since Flutter has nothing better on a 1x GL root. Patch 0003 (`use_sdfs`) adds analytic AA for circles and rounded rects on every backend.

## 4. Gaps ranked by production risk

1. **Crash / frozen screen:** an Android Vulkan swapchain that goes OUT_OF_DATE is never recreated. Flutter retries and recreates [F:engine/src/flutter/impeller/renderer/backend/vulkan/swapchain/khr/khr_swapchain_vk.cc:L79-L115].
2. **Memory / crash:** images decode at full source size with no max-texture clamp and no thread bound (A3 §14.2).
3. **App kill:** no GPU-availability switch, so iOS would keep submitting GPU work in the background.
4. **Jank:** a single thread does everything; no explicit vsync; NativeAnimated is coupled to the JS thread.
5. **Wrong pixels:** stroked paths alias on any GL root without supersample. Resize has no stale-frame guard, and its gate checks timing, not geometry.
6. **Silent GPU misuse:** Metal API validation and Vulkan validation layers have never been switched on (A4 §4.4).
7. **Undetected regressions:** no frame-time recorder, no p95/p99 budgets, no trace spans. CI only renders on llvmpipe.
8. **Untested input surfaces:** no ASan/UBSan/TSan on our code, and no fuzzing of the props, SVG path or image-decode parsers (A4 §4.2-4.3).
9. **Feature holes:** no LayoutAnimation, no backdrop blur (the `SaveLayer` backdrop is always null), no external textures, no platform views (WebView/video/camera), no snapshot/toImage.
10. **First-use stalls:** pipeline variants nobody has warmed up compile synchronously on first use (A2 §7). Flutter pre-warms (A2 §12.3).

## 5. Roadmap

Ordering rule: **instruments first**. "Bulletproof" can't be proven without frame timings, sanitizers and validation layers, and every later gate reads them. Then threads, then backends, then the platform contract, then features. Each item lands the way ours always do: a pushed SHA, a gate that PASSES, mutants that FAIL.

### Phase 0: instruments (about 1 week)

- **RX-01 Frame-timing recorder + trace spans.** Model: Flutter's `FrameTimingsRecorder` state machine and `TRACE_EVENT` (A4 §4.7-4.8). Record vsync, build start/end, raster start/end and present per frame. Export to RN's `FrameTimingSequence` / PerformanceObserver and to a Chrome-trace JSON. Gate: a 120-frame animated fixture yields a monotonic, complete record for every frame plus p50/p95/p99. Mutant: skip the raster-start stamp on idle-skip frames.
- **RX-02 Sanitizer builds.** ASan+UBSan and TSan CMake presets, with the existing gate suite run under them. Gate: suite clean. Mutants: one deliberate out-of-bounds read (ASan), and the `SceneGraph` mutex dropped on one path (TSan).
- **RX-03 Validation layers on in CI.** `MTL_DEBUG_LAYER=1` + shader validation on the Mac; `VK_LAYER_KHRONOS_validation` for Vulkan. Gate: zero validation errors across the suite. Mutant: a wrong `VkImageLayout` / an out-of-range texture binding.

### Phase 1: frame pipeline and threads (about 2-3 weeks)

- **RX-10 NativeAnimated on the platform thread at vsync.** Drive `onRender` from our frame scheduler, matching RN's UI-tick contract (§2), not `scheduleWork`. Gate: a 50 ms JS stall every other frame adds no more than one vsync of latency to a running `Animated.timing` (`useNativeDriver: true`). Mutant: today's HEAD must go RED.
- **RX-11 Real vsync + FrameScheduler.** `RequestFrame` dedupe, per-OS vsync (CVDisplayLink, swap interval 1, Choreographer). Gate: present-interval stddev under 10% of the refresh period over 120 frames. Mutant: swap interval 0.
- **RX-12 Raster thread + immutable snapshot pipeline (depth 2).** Mount on main produces a frozen render-tree snapshot; the raster thread turns it into the display list and presents. Model: `Pipeline<T>` / `Animator` / `Rasterizer`. Gate: a 50 ms main-thread stall with a queued frame still presents within one vsync of the stall ending; 1,000 commit-during-raster iterations show zero torn frames. Mutant: the raster side reads the live tree.
- **RX-13 IO pool + decode clamp + off-thread upload.** Decode in a bounded pool, resize to the `<Image>` box, clamp to max texture size, upload off the raster thread (Metal/Vulkan direct; GL through a shared context). Gate: 200 distinct images keep threads at or below cores+2; an 8000x6000 PNG in a 200x200 box stays under 50 MB RSS and uploads at most 400x400 at 2x. Mutants: HEAD (unbounded threads), and the clamp removed.

### Phase 2: backends (about 2-3 weeks)

- **RX-20 darwin native Metal (windowed).** `ImpellerContextCreateMetalNew` + `ImpellerSurfaceCreateWrappedMetalDrawableNew` on a CAMetalLayer, presented from the raster thread. Remove ANGLE from the darwin windowed path. Gate: the icon-edge AA metric at supersample 0 matches or beats today's N=4 result on hardware, and the style-audit grid stays green. Mutant: force the GL path; the AA metric must fail.
- **RX-21 SDK patch 0003: plumb `Flags.use_sdfs`.** Gate: a rounded-rect / circle fixture gains partial-coverage pixels on GL with supersample off. Mutant: flag ignored.
- **RX-22 SDK patch 0004: Metal offscreen texture surface.** Headless darwin gates then render on real Metal, not ANGLE. Gate: per-pixel match against the windowed capture. Mutant: wrong pixel format.
- **RX-23 Android: swapchain recreate + GLES fallback + bad-driver list.** Gate: 20 rotations, zero frozen frames; with a forced bad driver the app still renders via GLES. Mutants: no recreate; no fallback wiring.

### Phase 3: platform contract (about 2 weeks)

- **RX-30 Resize synchronizer + stale-frame discard.** Gate: across 10 random fast resizes, a reference shape's aspect error stays at or under 2% in every captured frame. Mutant: skip the relayout for one resize.
- **RX-31 GPU availability switch** on AppState background/inactive. Gate: zero submit/present calls while backgrounded. Mutant: paint loop ignores the flag.
- **RX-32 Context / device loss recovery** (GL context lost, Vulkan device lost): rebuild the context and re-upload textures from the CPU cache. Gate: a forced loss mid-run recovers within 2 frames. Mutant: no re-upload, so images come back black.
- **RX-33 Memory pressure:** LRU image cache + glyph/texture caps + a low-memory purge hook. Gate: the long-session working set plateaus. Mutant: purge is a no-op.

### Phase 4: features RN apps expect (about 3-4 weeks)

- **RX-40 LayoutAnimation** (`UIManagerAnimationDelegate` / `LayoutAnimationKeyFrameManager`). Gate: more than one intermediate frame. Mutant: `nullptr` (HEAD).
- **RX-41 Backdrop filters** (blur behind a card). Model: `Canvas::ApplyBackdropFilter`. Gate: lower variance inside the card than a control, unchanged pixels outside. Mutant: backdrop null (HEAD).
- **RX-42 External textures + texture registry** (video/camera frames). Model: `flow/layers/texture_layer.cc`. Gate: a registered texture is drawn under clip + rotate. Mutant: transform/clip not applied.
- **RX-43 Platform views** (real OS views for WebView/maps). Model: `flow/embedded_views.h` mutator stack. Gate: a native view tracks its RN box through scroll and transform. Mutant: one transform skipped.
- **RX-44 Snapshot / toImage** (view-shot). Gate: snapshot equals an on-screen crop. Mutant: Y-flip.
- **RX-45 Pipeline pre-warm tour** at startup. Gate: the first use of each blend/stencil combo stays under budget. Mutant: tour skipped.

### Phase 5: enterprise quality bar (ongoing; starts in parallel with Phase 1)

- **RX-50 Fast in-process tests on display-list output.** Flutter runs 723 backend-parameterized `TEST_P`s via `INSTANTIATE_PLAYGROUND_SUITE` (A4 §4.1). Ours: render-tree snapshot → draw-op dump assertions, under 2 s, alongside the existing 101 `ci-*` gates and 92 mutation scripts.
- **RX-51 Per-backend goldens with a tolerance policy.** We go beyond Flutter here: its Impeller goldens run on macOS/Metal only [F:engine/src/flutter/impeller/golden_tests/README.md:L19-L20]. Ours: Metal, ANGLE-D3D11, GLES-Mesa, Vulkan. Mutant: 1 LSB colour shift stays PASS (tolerance works); a 1 px offset FAILS.
- **RX-52 Fuzzing:** Fabric prop parsers, SVG path + dash parser, image decoders, display-list builder; a nightly 10-minute corpus under ASan.
- **RX-53 Perf budgets:** p95/p99 build and raster per fixture, with alarms against a 10-run baseline.
- **RX-54 Real-hardware CI matrix:** Mac (Metal), Windows (ANGLE-D3D11), Android emulator + 1 device (Vulkan + GLES). The macOS tester's manual measuring becomes an unattended job.

## 6. What we deliberately do NOT copy

- **Raster cache:** Flutter turns it off under Impeller (§2).
- **Dart isolates / engine groups:** no RN equivalent. Multi-surface sharing comes later, if ever.
- **Impeller Scene (3D):** removed upstream; out of scope.
- **Flutter's macOS-only goldens:** we test every backend we ship.

## 7. Open questions (need a measurement, not an opinion)

- Does ANGLE-Metal expose `GL_EXT_multisampled_render_to_texture`? If it does, save-layer offscreens on darwin GL already get 4x MSAA [F:engine/src/flutter/impeller/renderer/backend/gles/capabilities_gles.cc:L173-L178]. A 5-minute Mac probe answers it.
- Vulkan on lavapipe for Linux CI: is it fast enough? Unmeasured. We keep GLES on Linux anyway (parity), so this only matters for a Vulkan CI lane.
- Hermes idle-time GC hint (Flutter's NotifyIdle equivalent): not checked.
- RN 0.86 `LayoutAnimationKeyFrameManager` is compiled into our build? Only seen in build artifacts so far.

## 8. Next step

Approve Phase 0 + RX-10 as the first slice. RX-10 is the one that's visibly broken for users today: native animations stall when JS is busy. Its gate is designed to go RED on today's HEAD, so the fix proves itself.
