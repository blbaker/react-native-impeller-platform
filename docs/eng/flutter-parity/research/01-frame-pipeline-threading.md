# 01 — Frame Pipeline + Threading

Pinned Flutter SHA: `114eb184d66d7ca136d89eb8ec09f61aff265062` (2026-08-09). Our tree:
this repo @ `840961d` (`feat/native-anim-transform`), read-only.

## 1. How Flutter does it

### 1.1 The four task runners (embedder-owned, not engine-owned)
The engine does not create threads; the **embedder** hands it 4 task runners and must keep
each one pinned to one thread for the engine's life: **Platform**, **UI**, **Raster**, **IO**
[F:docs/about/The-Engine-architecture.md:L96-103].

- **Platform**: the embedder's main thread. All embedder↔engine calls must happen here;
  platform messages and input are pumped here too. Blocking it risks an OS watchdog kill and
  dropped gestures, but does **not** block the render pipeline [F:docs/about/The-Engine-architecture.md:L105-146].
- **UI** ("the Dart thread"): runs the root isolate. Per frame: update animations → rebuild
  widgets → layout+paint into a `LayerTree` (a description, nothing rasterized yet) → update
  the semantics tree [F:docs/about/The-Engine-architecture.md:L148-175]. A few ms of
  synchronous Dart work here is enough to miss a frame.
- **Raster**: turns the `LayerTree` into backend draw commands and submits to the GPU. Normally
  a separate thread from UI so raster can still be mid-submit for frame N while UI is already
  building frame N+1 — pipelining — bounded so UI can't outrun the rasterizer
  [F:docs/about/The-Engine-architecture.md:L199-226].
- **IO**: decodes/uploads textures on a context in the same GL/Vk sharegroup as the raster
  context, so `ui.Image` resolves asynchronously without the raster thread blocking on decode
  [F:docs/about/The-Engine-architecture.md:L228-261].

### 1.2 The frame request → vsync → build → raster cycle (concrete call order)
1. **Request**: `Animator::RequestFrame()` takes `pending_frame_semaphore_` (count 1 — only one
   outstanding vsync request at a time), then posts `AwaitVSync` onto the UI task runner, which
   calls `VsyncWaiter::AsyncWaitForVsync(callback)` [F:shell/common/animator.cc:L239-271].
2. **Vsync fires** → `Animator::BeginFrame()`: if reusable, draws the last layer trees instead
   (`CanReuseLastLayerTrees`/`DrawLastLayerTrees`); else it asks the frame pipeline for a
   producer continuation (`layer_tree_pipeline_->Produce()`). If the pipeline is already full
   (raster hasn't drained — **backpressure**), it re-requests the *next* vsync and bails
   (`TRACE_EVENT0("flutter","PipelineFull")`) instead of blocking
   [F:shell/common/animator.cc:L61-112].
3. `delegate_.OnAnimatorBeginFrame()` runs Dart's `drawFrame`; the framework calls
   `Animator::Render(view_id, layer_tree, dpr)` per view, buffered in `layer_trees_tasks_`
   [F:shell/common/animator.cc:L188-210].
4. `Animator::EndFrame()` packs all per-view tasks into one `FrameItem` and completes the
   producer continuation. The delegate (`Rasterizer`/`Shell`) is only poked via `OnAnimatorDraw`
   if this was the pipeline's first/only queued item — otherwise the already-scheduled raster
   consumer will pick it up [F:shell/common/animator.cc:L121-166].
5. **Idle hint**: if no new frame is scheduled ~51ms (>3×60Hz frames) after the last vsync
   deadline, `OnAnimatorNotifyIdle` fires → `Engine::NotifyIdle` → `RuntimeController::NotifyIdle`
   → `Dart_NotifyIdle(deadline)` — a real GC hint, not just a log line
   [F:shell/common/animator.cc:L17-20,166-186; F:shell/common/engine.cc:L304-306;
   F:shell/common/shell.cc:L1408-1414; F:runtime/runtime_controller.cc:L319-341].

### 1.3 Pipeline: depth, Produce/Consume, continuation
`Pipeline<R>` is a bounded, thread-safe single-producer/single-consumer queue built from two
semaphores (`empty_`, `available_`). `Produce()` returns a `ProducerContinuation` only if a slot
is free; `Complete(resource)` enqueues and signals; `Consume(consumer)` blocks-free-waits on
`available_`, pops, and signals `empty_` back [F:shell/common/pipeline.h:L58-230]. Depth is **2**
for Metal, else **1** if the platform and raster task runners are the *same* thread (no
cross-thread pipelining is possible anyway), **2** otherwise
[F:shell/common/animator.cc:L25-41].

### 1.4 Rasterizer: Draw → DoDraw → DrawToSurfaces(Unsafe), resubmit, discard, thread merging
- `Rasterizer::Draw(pipeline)`: if a `raster_thread_merger_` exists and this call isn't
  currently on the merged/rasterizing thread, it **yields** (`DrawStatus::kYielded`) rather than
  racing [F:shell/common/rasterizer.cc:L248-254]. It consumes exactly one `FrameItem` →
  `DoDraw` → `DrawToSurfaces` → `DrawToSurfacesUnsafe`.
- **Discard-on-resize**: `DrawToSurfacesUnsafe`'s first pass drops any per-view task whose
  `Shell::ShouldDiscardLayerTree(view_id, tree)` is true — i.e. the tree's `frame_size` doesn't
  satisfy the view's current `ExpectedFrameConstraints` (guarded by `resize_mutex_`, updated from
  `OnViewportMetricsChanged`) [F:shell/common/rasterizer.cc:L644-658;
  F:shell/common/shell.cc:L1860-1866,L1174-1182,L2517-2525]. This is the concrete
  "never present a stretched frame" guard.
- **Raster cache is force-disabled under Impeller**: `Surface::EnableRasterCache()` defaults
  `true` [F:flow/surface.cc:L25-27], but **all three** Impeller GPU surfaces override it to
  `false` — `GPUSurfaceMetalImpeller`, `GPUSurfaceVulkanImpeller`, `GPUSurfaceGLImpeller`
  [F:shell/gpu/gpu_surface_metal_impeller.mm:L371-374; shell/gpu/gpu_surface_vulkan_impeller.cc:L310-313;
  shell/gpu/gpu_surface_gl_impeller.cc:L169-172]. `Rasterizer::DrawToSurfaceUnsafe` reads that
  flag straight into `ignore_raster_cache` before calling `CompositorContext::ScopedFrame::Raster`
  [F:shell/common/rasterizer.cc:L806-812]. (If it *weren't* disabled: `RasterCache::Rasterize`
  falls back to a CPU `SkSurfaces::Raster` when `context.gr_context` is null, which it always is
  on the Impeller path — so even a hypothetical re-enable would not get GPU-cached tiles
  [F:flow/raster_cache.cc:L89-96].)
- **Resubmit**: if `DrawToSurfaces` returns a `resubmitted_item` (e.g. the external view embedder
  asked for a retry, or a raster/platform thread-merge lease demands another pass),
  `Rasterizer::Draw` pushes it back to the **front** of the pipeline via `ProduceIfEmpty()` and
  re-posts itself on the raster task runner [F:shell/common/rasterizer.cc:L267-283,L592-604].
- **Thread merging**: `EnableThreadMergerIfNeeded`/`DisableThreadMergerIfNeeded` wrap a
  `fml::RasterThreadMerger` so an `ExternalViewEmbedder` (platform views) can temporarily run
  raster work on the platform thread for a lease period [F:shell/common/rasterizer.cc:L161-171].

### 1.5 Partial repaint / diffing *is* used with Impeller, just gated differently
`CompositorContext::FrameDamage::ComputeClipRect` builds a `DiffContext` for **both** backends
(`impeller_enabled` is threaded straight into it) [F:flow/compositor_context.cc:L11-39]. But
`ScopedFrame::Raster` only actually applies the damage clip under Impeller if
`ShouldPerformPartialRepaint()` — the dirty rect must be ≤70% of width *or* height
(`kImpellerRepaintRatio = 0.7f`), because Impeller's partial repaint needs an extra offscreen
resolve texture plus a final blit, so a near-full-frame "partial" repaint is deliberately
promoted back to a full repaint [F:flow/compositor_context.cc:L183-224].

### 1.6 DisplayList → Impeller Canvas, and present
Each GPU surface's `AcquireFrame` returns a `SurfaceFrame` whose `EncodeCallback` calls
`surface_frame.BuildDisplayList()`, wraps the native drawable into an `impeller::Surface`, then
calls `impeller::RenderToTarget(...)`. That function runs a `FirstPassDispatcher` collection pass,
then `display_list->Dispatch(impeller_dispatcher, cull_rect)` against a `CanvasDlDispatcher`
(an `impeller::DlDispatcherBase` subclass) — this is the literal point a `flutter::DisplayList`
turns into Impeller `Canvas`/Aiks draw calls [F:shell/gpu/gpu_surface_metal_impeller.mm:L97-222;
F:impeller/display_list/dl_dispatcher.cc:L1309-1337; F:impeller/display_list/dl_dispatcher.h:L65,L309].
On macOS/iOS, `presentsWithTransaction` is set **inside that same encode callback**, directly on
the `CAMetalLayer`, from `surface_frame.submit_info().present_with_transaction`
[F:shell/gpu/gpu_surface_metal_impeller.mm:L124-126] — it is not a separate present-time step.

### 1.7 Resize synchronization
- **macOS**: `ResizeSynchronizer` (Swift). The platform thread's `beginResize(forSize:)` **blocks**
  (pumping Flutter messages via `FlutterRunLoop`) until the raster thread's
  `performCommit(forSize:)` reports a frame at the matching size, or a 1s timeout
  [F:shell/platform/darwin/macos/framework/Source/ResizeSynchronizer.swift:L9-33,L75-113]. This
  is the direct fix for "window already resized, Flutter still painting the old size."
  (Class is `@objc(FlutterResizeSynchronizer)`, not literally named `FlutterThreadSynchronizer`
  at this SHA — brief's name is stale; confirmed via `find … -iname '*ThreadSynchronizer*'` → no
  hits, `-iname '*Synchroniz*'` → this file.)
- **Every platform**, additionally: the engine-level discard guard in §1.4
  (`ShouldDiscardLayerTree`/`ExpectedFrameConstraints`) is the backstop that works even without a
  platform-specific blocking synchronizer.

### 1.8 Vsync source per OS
macOS → `CVDisplayLink` in `FlutterDisplayLink.mm` [F:shell/platform/darwin/macos/framework/Source/FlutterDisplayLink.mm:L42-64].
iOS → `CADisplayLink` via `VSyncClient.swift`/`DisplayLinkManager.swift`
[F:shell/platform/darwin/ios/framework/Source/VSyncClient.swift; F:shell/platform/darwin/ios/framework/Source/DisplayLinkManager.swift].
Android → `impeller::android::Choreographer` [F:shell/platform/android/vsync_waiter_android.cc:L31-38].
Generic/custom embedders (desktop Linux/Windows at this layer) → `VsyncWaiterEmbedder`, which
takes its vsync callback from the embedder [F:shell/platform/embedder/vsync_waiter_embedder.h].
(No native DXGI/X11/Wayland waiter in this corpus: `find shell/platform/linux shell/platform/windows
-iname "*vsync*"` → no hits; desktop embeddings route through the generic path above.)

## 2. The RN-way equivalent

- **JS thread ≈ Flutter's UI/Dart thread.** Both own the single language runtime that must
  never run native blocking work and both are the place animations/build happen. React Native
  doesn't have a Dart-isolate-style secondary-worker convention in `ReactCommon`; heavy JS work
  has no engine-level offload here (not confirmed beyond this subsystem).
- **Fabric commit → mount**: `ShadowTree` revisions are immutable; `MountingCoordinator::pullTransaction()`
  diffs the base vs. latest revision into a `MountingTransaction` — this is RN's analogue of
  Flutter's immutable `LayerTree` handed from UI thread to raster thread: a versioned, read-only
  snapshot crossing a thread boundary, not a live mutable tree
  [RN:react/renderer/mounting/MountingCoordinator.h:L26-32,L59-65]. Stock RN pulls+mounts this
  asynchronously relative to JS (comment: "Android... calls `pullTransaction` from the JS thread
  and schedules the updates asynchronously on the UI thread" [RN:react/renderer/mounting/MountingCoordinator.h:L50-57]).
- **RuntimeScheduler** is the event-loop/priority-scheduling equivalent of the UI task runner's
  per-vsync `drawFrame` step: `scheduleRenderingUpdate(surfaceId, renderingUpdate)` is literally
  "do a commit+mount now", and `callExpiredTasks` drains ready work
  [RN:react/renderer/runtimescheduler/RuntimeScheduler.h:L47-48,L145-147].
- **UIManagerAnimationDelegate / LayoutAnimationKeyFrameManager**: the seam for RN's *declarative*
  `LayoutAnimation.configureNext` — Scheduler calls into it to intercept/replay mutations across
  several frames [RN:react/renderer/uimanager/UIManagerAnimationDelegate.h:L16-43]. Flutter has no
  equivalent hook; it just drives an `AnimationController` through the same per-vsync Dart
  callback as everything else.
- **What plays `Animator::RequestFrame`/`BeginFrame` for RN's *native-driven* Animated**:
  `NativeAnimatedNodesManager::onAnimationFrame(timestamp)` /
  `onAnimationFrameForBackend(propsBuilder, timestamp)` — a per-frame tick that walks the animated
  node graph and emits prop mutations [RN:react/renderer/animated/NativeAnimatedNodesManager.h:L127,L208].
  `ReactCommon` only defines the manager; it does **not** define who calls `onAnimationFrame` each
  frame or on what thread — that driver is platform-specific (not confirmed further in this
  corpus; out of scope per brief's subsystem split).
- **Where a "raster thread" would sit**: nothing in `ReactCommon` owns a GPU/raster thread —
  Fabric's contract ends at "hand the platform a `MountingTransaction`," assuming the platform
  mounts onto real native views synchronously on its own UI thread. A host that *paints* instead
  of mounting views (ours) must insert its own raster stage **after** `pullTransaction()`,
  consuming the same kind of versioned, immutable snapshot Flutter's raster thread consumes — in
  our case that should be a retained-tree *revision*, not the live mutable tree.

## 3. Our engine today

**One thread (the main/platform thread) does everything**: event polling, full-tree paint,
GPU submit, and present. The JS thread is the only other thread in the steady-state render path.

- **`paintFrame()`** (captured lambda, not a free function): takes `GlfwSurface::PaintScope`
  (re-entrancy guard against `eglSwapBuffers`→`CAMetalLayer`→AppKit re-entering mid-paint),
  builds a **fresh** `ImpellerDisplayListBuilder` every call, calls `sceneGraph.paint(builder, …)`
  (walks the **whole** retained tree under `mutex_` — confirmed: `SceneGraph::paint` takes
  `std::lock_guard<std::mutex> lock(mutex_)` then calls `paintLocked`
  [R:engine/scenegraph/Modal.cpp:L15-21]), submits via `surface.drawDisplayList(dl)`, then
  `surface.present()` (`eglSwapBuffers`/`glfwSwapBuffers`) [R:engine/host/main.cpp:L621-662].
  **No `glfwSwapInterval`/`eglSwapInterval` call exists anywhere under `engine/host/`**
  (`grep -rln "SwapInterval" engine/host/` → no hits) — frame pacing is whatever the GL/EGL
  driver defaults to, not an explicit vsync wait.
- **Idle-skip + scene version** (the closest thing we have to backpressure/vsync gating):
  `SceneGraph::version()` is an atomic bumped by any mutation (`bumpVersion()`, called from
  `applyMutations`/`updateViewProps` on the JS thread and from `WorldRasterStore` pixel writes)
  [R:engine/scenegraph/SceneGraph.h:L578-600]. The windowed loop (`--idle-skip`, default **on**
  in interactive mode) computes `shouldPaint` from: version advanced since last present, a
  "clockLive" flag (a NativeAnimated tick fired this frame, a focused caret, a spinner), the
  first frame, or a frame-anchored test hook still pending
  [R:engine/host/main.cpp:L1187-1230]. When clean, it calls `surface.waitEvents(idleBudgetMs/1000.0)`
  (default 250ms) instead of busy-polling, and a damage "wake" (`glfwPostEmptyEvent`, installed
  via `SceneGraph::setDamageWake`) lets an off-thread version bump interrupt that sleep promptly
  [R:engine/host/main.cpp:L1031-1053,L1541-1552].
- **SceneGraph mutex**: ONE `std::mutex mutex_` guards the whole retained tree; `applyMutations`
  (JS thread) and `paint` (main thread) both take it [R:engine/scenegraph/SceneGraph.cpp:L1149-1151;
  R:engine/scenegraph/Modal.cpp:L15-21] — i.e. paint and commit are serialized by a lock, not by a
  pipeline of immutable snapshots.
- **JsThread**: `std::thread` + a FIFO `std::deque` + a timer min-heap implementing
  `facebook::react::MessageQueueThread`; Hermes lives here for the process's whole life
  [R:engine/runtime/JsThread.h:L1-7,L21-40,L79-90].
- **FabricHost → Scheduler**: constructed with `/*animationDelegate*/ nullptr`
  [R:engine/fabric/FabricHost.cpp:L679-680] — RN's declarative `LayoutAnimation` hook
  (`UIManagerAnimationDelegate`) is entirely unwired. `ImpellerSchedulerDelegate::schedulerShouldRenderTransactions`
  pulls **exactly one** `MountingTransaction` per call (comment explicitly warns against a drain
  loop because of the LayoutAnimation KFM override path) and feeds it straight to
  `SceneGraph::applyMutations` [R:engine/fabric/FabricHost.cpp:L126-139].
- **Native-driven Animated tick**: `ReactHost::pumpNativeAnimated()` advances a static
  frame-counted clock, then does `scheduler->scheduleWork([pump]{ pump->tick(); })` — i.e. even
  "native-driven" prop application is queued **behind every other JS-thread task** in the shared
  FIFO, not applied independently of JS load [R:engine/runtime/ReactHost.cpp:L485-505]. It is only
  *called* from inside the main/paint loop body, so under `--idle-skip`, if the loop is parked in
  `waitEvents`, a live animation gets no tick until something else wakes the loop
  (capped at `idleBudgetMs`, default 250ms, by construction — not independently measured here).
- **First-present wait**: `paintsTotal` is incremented inside `paintFrame()` at the moment of
  `present()`; on `paintsTotal==1` it stamps `SinceLaunchMs()` and emits a `firstFramePresented`
  **device event** to JS [R:engine/host/main.cpp:L643-662] — this is our analogue of Flutter's
  `Shell::WaitForFirstFrame`, but it is a one-shot JS event, not a blocking call any native caller
  can await.
- **Images**: `ImageStore` spawns a **new detached `std::thread` per image** for `stb_image`
  decode, with no pool and no shared-context analogue of Flutter's single IO task runner
  [R:engine/fabric/ImageStore.cpp:L219-230].
- **Headless loop**: a bounded `for (frameIndex = 1..frames)` loop that calls
  `pumpNativeAnimated()` then **blocks** on `host.waitForJsIdle(5000)` before every paint — a
  completely different pacing model from the windowed loop, with no idle-skip and no vsync
  concept [R:engine/host/main.cpp:L2868-2900].
- No idle-time GC hint exists anywhere in the host: `grep -rn "NotifyIdle\|IdleCollect\|LowMemory"
  engine/host/main.cpp engine/runtime/*.cpp engine/fabric/*.cpp` → no hits.
- Existing resize gates: `tools/ci-resize.sh`/`tools/mutation-verify-resize.sh` exist and assert
  *timing* (a resize mid-stall still repaints, frame counts) — grepped for `stretch|aspect|pixel`
  in `ci-resize.sh` → no hits; it does **not** assert on-screen geometry/aspect-ratio correctness.

## 4. Gaps, ranked by risk

1. **(Jank/contract violation)** Native-driven Animated round-trips through the JS thread's
   shared FIFO (`pumpNativeAnimated`→`scheduleWork`) instead of applying independently of JS load.
   A JS stall delays or drops frames of an animation whose entire purpose is to survive JS stalls.
   No Flutter equivalent risk is this specific, because Flutter never promises an "independent of
   the UI thread" animation path in the first place — RN's NativeAnimated contract does.
2. **(Jank)** No explicit vsync wait anywhere in `engine/host/` — pacing is accidental. Flutter
   has a concrete per-OS `VsyncWaiter` feeding a semaphore-gated, single-outstanding-request
   `Animator`.
3. **(Jank)** One thread does input-poll + full-tree walk + DisplayList build + GPU submit +
   present. A slow paint blocks input handling and starves the JS thread's chance to get mutations
   drained before the next paint; Flutter's 4 runners let UI-build and raster pipeline 1-2 frames
   deep so a slow raster frame doesn't block the next frame's build.
4. **(Wrong pixels, partially mitigated)** No equivalent of `ShouldDiscardLayerTree`/
   `ExpectedFrameConstraints`: nothing refuses to present a frame built for a stale surface size.
   Single-threadedness and the `set→relayout→emit` ordering in `applyResizeIfDirty` make the
   specific Flutter bug less likely, but there is no synchronization primitive (like
   `ResizeSynchronizer`) that *proves* it, and the existing resize gate checks timing, not geometry.
5. **(Resource exhaustion)** `ImageStore` spawns one unbounded detached thread per image decode;
   a long image list can spawn hundreds of OS threads concurrently, vs. Flutter's single IO task
   runner + bounded Dart VM pool.
6. **(Feature gap)** `animationDelegate = nullptr` means RN's declarative `LayoutAnimation` API
   is a complete no-op; any component relying on `LayoutAnimation.configureNext` silently gets an
   instant snap instead of a transition.
7. **(Memory, unverified)** No idle-time GC hint call found anywhere in the host (see grep above).
   Flutter explicitly hints Dart's GC after ~3 idle vsyncs; whether Hermes needs/has an analogous
   hook was not checked here (out of this subsystem's budget) — flagged, not confirmed either way.

## 5. Work items

**1. Split the single thread into platform(main) + raster, connected by a bounded pipeline.**
Model: `shell/common/pipeline.h` (`Pipeline<T>::Produce`/`Complete`/`Consume`) +
`shell/common/animator.cc` (`RequestFrame`/`BeginFrame`/`EndFrame`). Hand the raster side an
**immutable snapshot** of the scene (a revision, not the live `mutex_`-guarded tree).
- *Gate*: inject a synthetic 50ms stall on the platform thread while a fully-built frame is
  queued; the frame must still present within one vsync interval of the stall ending, not be
  delayed by the full stall length.
- *Mutant*: feed the raster side directly off the live `SceneGraph` (skip the snapshot handoff).
  Gate must catch torn-frame pixels (partial mutation visible) when a commit lands mid-raster
  across N concurrent-mutation/raster stress iterations.

**2. Add a real per-OS vsync wait** (`eglSwapInterval(1)` minimum; `CVDisplayLink` on macOS
modeled on `FlutterDisplayLink.mm`). 
- *Gate*: over 120 frames of a continuously-animating scene, present-to-present interval stddev
  must be <10% of the monitor refresh interval.
- *Mutant*: force `eglSwapInterval(0)`/no-wait; gate must fail (variance blows up).

**3. Decouple the NativeAnimated tick from the shared JS FIFO** — give it a dedicated lane or
apply it directly against a lock-free snapshot of the animated graph, instead of
`scheduler->scheduleWork`. Model: Flutter never schedules *any* native task onto the UI task
runner [F:docs/about/The-Engine-architecture.md:L176-186] — the thread that drives animation
frames carries no other blocking work.
- *Gate*: inject a 50ms JS-thread stall every other frame during a running native-driven
  `Animated.timing()`; no presented frame may lag by more than one vsync interval (~16.7ms) of
  extra latency beyond the stall, measured via `nativeAnimatedTickMicros()` deltas.
- *Mutant*: **today's committed code is the failing mutant** — the gate must be RED on HEAD
  (`scheduleWork` round-trip) and only GREEN once the tick path no longer waits behind arbitrary
  JS work.

**4. Wire a minimal `UIManagerAnimationDelegate`** instead of `nullptr`. Model (not yet read in
depth; file confirmed present only via build artifacts, flagged not-confirmed):
`react/renderer/animations/LayoutAnimationKeyFrameManager.h`.
- *Gate*: a component wrapped in `LayoutAnimation.configureNext` before a layout-changing
  `setState` must show >1 captured intermediate frame between old and new layout.
- *Mutant*: current `nullptr` delegate is the failing mutant — confirm RED (instant snap, 0
  intermediate frames) on HEAD.

**5. Pixel-level anti-stretch resize gate.** Extend `tools/ci-resize.sh`/
`tools/mutation-verify-resize.sh` to sample a fixed reference shape's aspect ratio from captured
frames across a resize-drag stress sequence. Model: `Shell::ShouldDiscardLayerTree`/
`ExpectedFrameConstraints` [F:shell/common/shell.cc:L1860-1866,L2517-2525] and
`ResizeSynchronizer`'s commit-size matching [F:…/ResizeSynchronizer.swift:L75-113].
- *Gate*: across N scripted resizes, zero captured frames may show the reference shape's aspect
  ratio off by >2% from the window's size at capture time.
- *Mutant*: drop the `fabric.updateSurface(...)` relayout call for one resize in the sequence
  (keep `set`+`emit`) — must produce a stretched frame that today's timing-only gate misses but
  the new geometry gate catches.

**6. Bound image-decode concurrency.** Replace `ImageStore`'s per-image detached thread with a
small fixed worker pool. Model: the IO task runner + Dart VM thread pool
[F:docs/about/The-Engine-architecture.md:L228-249].
- *Gate*: render a 200-distinct-image list; peak concurrent decode-thread count must stay at or
  below a fixed cap (e.g. CPU core count + 2).
- *Mutant*: current per-image detached-thread code is the failing mutant — confirm RED by
  counting live threads during the 200-image stress run.
