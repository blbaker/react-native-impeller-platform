# 2. Impeller internals (the renderer itself)

Pin: flutter/flutter @ `114eb184d66d7ca136d89eb8ec09f61aff265062` (2026-08-09). `[F:...]` = permalink
`https://github.com/flutter/flutter/blob/114eb184d66d7ca136d89eb8ec09f61aff265062/<path>#L<a>-L<b>`.
`[R:...]` = `a local worktree`. `[RN:...]` = under `engine/rn/node_modules/react-native`.
`[W:...]` = fetched URL.

## 0. Pipeline overview

**RN-way equivalent**: stock RN 0.86 has no renderer-internals analog — Fabric's `ShadowTree`/
`MountingCoordinator` [RN:ReactCommon/react/renderer/mounting/ShadowTree.h]
[RN:ReactCommon/react/renderer/mounting/MountingCoordinator.h#L34-L34] commit a host-view tree and
hand it to the platform (UIKit/Android views, or Skia in `react-native-skia`) to paint. `rn-impeller`
*is* that platform renderer — our `SceneGraph` plays the role a Skia/UIKit canvas would, built
directly on Impeller's interop API. See §10 for exactly what it uses.

`flutter::DisplayList` ops are replayed through `CanvasDlDispatcher : DlDispatcherBase`
[F:engine/src/flutter/impeller/display_list/dl_dispatcher.h#L65-L65] (base) and
[F:engine/src/flutter/impeller/display_list/dl_dispatcher.h#L309-L309] (concrete), which forwards
every `draw*`/`clip*`/`save*` op 1:1 to an `impeller::Canvas`
[F:engine/src/flutter/impeller/display_list/dl_dispatcher.cc#L555-L600] (`drawOval`, `drawCircle`,
`drawRoundRect`, `drawRoundSuperellipse`, `drawPath`), `#L302-L500` (`save`/`saveLayer`/`clipRect`/
`clipOval`/`clipRoundRect`/`clipRoundSuperellipse`/`clipPath`). `AiksContext` (Aiks = the historic
internal name for the 2D API layer) is a thin pair: an `impeller::Context` (HAL) +
`ContentContext` (pipeline/pass orchestration) [F:engine/src/flutter/impeller/display_list/aiks_context.cc#L1-L46].
`Canvas` [F:engine/src/flutter/impeller/display_list/canvas.h#L119-L119] owns a stack of
`LazyRenderingConfig`/`EntityPassTarget` render passes (`render_passes_`), a clip-coverage stack
(`EntityPassClipStack clip_coverage_stack_` [F:engine/src/flutter/impeller/display_list/canvas.h#L303-L303]),
and a transform stack; this *is* the "experimental canvas" — at this pin there is no separate
`EntityPass` tree builder, `Canvas` performs pass collapsing inline as it walks the DisplayList
once (single pass, no two-phase build). Each draw call builds an `Entity` (transform + blend mode +
`Contents`) [F:engine/src/flutter/impeller/entity/entity.h#L26-L26,L158-L160] and renders it
immediately into the current `RenderPass` the backend HAL exposes (`Context`, `CommandBuffer`,
`RenderPass`, `BlitPass`, `PipelineLibrary`, `Allocator`, `HostBuffer`, `SamplerLibrary`,
`Capabilities` — all under `impeller/renderer`). Backends (`impeller/renderer/backend/{metal,vulkan,gles}`)
implement that HAL; Impeller never generates shader source at runtime (see §7).

## 1. Anti-aliasing — the critical section

Impeller has **two independent, non-overlapping AA mechanisms**, and which one a draw call gets
depends on the shape type and a context-wide flag that is **not reachable from the standalone
interop C API we consume**.

**(a) Analytic SDF AA — gated behind `Flags::use_sdfs`, default `false`, and hard-coded `false` in
the standalone SDK.** `Canvas::DrawCircle`/`DrawOval`/`DrawRoundRect`/`DrawRoundSuperellipse` each
check `renderer_.GetContext()->GetFlags().use_sdfs && IsCompatibleWithSDFRendering(paint)` before
routing into `UberSDFGeometry`/`UberSDFContents`
[F:engine/src/flutter/impeller/display_list/canvas.cc#L1112-L1116] (round rect, gated additionally on
`radii.AreAllCornersCircular()`), `#L1197-L1210` (round superellipse), `#L1263-L1270` (circle). The
SDF fragment shaders (`circle.frag`, `uber_sdf.frag`) compute an exact signed distance and apply
`alpha = 1 - smoothstep(-fade, fade, sdf_distance)` with `fade` sized to ~half a device pixel via an
`aa_pixels` uniform [F:engine/src/flutter/impeller/entity/shaders/circle.frag#L50-L83]
[F:engine/src/flutter/impeller/entity/shaders/uber_sdf.frag#L1-L100] — this AA is **resolution- and
MSAA-independent**: it works identically on a 1x, non-MSAA framebuffer. `IsCompatibleWithSDFRendering`
excludes mask-blurred paint and several blend modes
[F:engine/src/flutter/impeller/display_list/canvas.cc#L2633-L2663]. `Flags::use_sdfs` defaults to
`false` [F:engine/src/flutter/impeller/base/flags.h#L9-L11]; inside the Flutter embedder it is
wired from a Dart-project / command-line setting `impeller_use_sdfs`
[F:engine/src/flutter/shell/common/switches.cc#L558-L558]. **The standalone interop SDK never
plumbs this through**: `ImpellerContextCreateMetalNew` calls
`impeller::ContextMTL::Create(Flags{}, ...)` with a literal default-constructed `Flags`
[F:engine/src/flutter/impeller/toolkit/interop/backend/metal/context_mtl.mm#L26-L30], and
`impeller::interop::Context::Context` never exposes a setter
[F:engine/src/flutter/impeller/toolkit/interop/context.cc#L10-L13]; `impeller.h` has no
`ImpellerContextSetFlags`/`...UseSDFs` symbol at all (checked: `grep -n "SDF\\|Flags" impeller.h` →
no hits). **Conclusion: regardless of backend (GLES, Metal, or Vulkan), consumers of the standalone
Impeller SDK — including us — can never get analytic SDF AA for circles/ovals/round-rects/round-
superellipses.** They always fall through to tessellated fills (below) and depend entirely on (b).

**(b) Device MSAA — the only AA any interop-SDK consumer actually gets, and it is backend-dependent
at the window-surface level.** Arbitrary paths (`Canvas::DrawPath`) *never* attempt the SDF branch —
`FillPathGeometry`/`StrokePathGeometry` are used unconditionally
[F:engine/src/flutter/impeller/display_list/canvas.cc#L458-L475] — and even tessellated round-rects/
circles (when `use_sdfs` is false, i.e. always for us) get zero analytic AA; their only defense
against aliasing is multisampling of the render target. `StrokePathGeometry` just emits an exact
outline polygon strip from caps/joins/miter math
[F:engine/src/flutter/impeller/entity/geometry/stroke_path_geometry.cc#L1-L60] — no coverage
blending, no feathering. Offscreen `EntityPass` targets (anything behind a `SaveLayer`, a clip
subpass, or a backdrop-filter readback) are allocated through `CreateRenderTarget`, which uses
`CreateOffscreenMSAA` whenever `Capabilities::SupportsOffscreenMSAA()` is true
[F:engine/src/flutter/impeller/display_list/canvas.cc#L145-L189]; the *root* pass only gets an
MSAA-sized depth/stencil if its color attachment **already** has `sample_count > 1`
[F:engine/src/flutter/impeller/display_list/canvas.cc#L1608-L1616], i.e. Canvas never upgrades a
1x surface to MSAA — that has to happen where the surface/swapchain is wrapped:
  - **Metal**: `SurfaceMTL::WrapCurrentMetalLayerDrawable` (what
    `ImpellerSurfaceCreateWrappedMetalDrawableNew` calls into) always allocates a transient 4x MSAA
    color texture as `color0.texture`, with the real `CAMetalDrawable` as a 1x `resolve_texture` and
    `store_action = kMultisampleResolve`
    [F:engine/src/flutter/impeller/renderer/backend/metal/surface_mtl.mm#L49-L89]. MSAA is automatic
    and free of app code.
  - **Vulkan**: `SwapchainVK::Create(..., bool enable_msaa = true)` defaults MSAA **on**
    [F:engine/src/flutter/impeller/renderer/backend/vulkan/swapchain/swapchain_vk.h#L36-L40], and the
    interop `ImpellerVulkanSwapchainCreateNew` path takes that default
    [F:engine/src/flutter/impeller/toolkit/interop/backend/vulkan/swapchain_vk.cc#L26-L31].
    `SwapchainTransientsVK::CreateMSAATexture` allocates `SampleCount::kCount4`,
    `StorageMode::kDeviceTransient`
    [F:engine/src/flutter/impeller/renderer/backend/vulkan/swapchain/swapchain_transients_vk.cc#L35-L48].
  - **GLES**: the *only* offscreen-surface constructor exposed by the interop SDK,
    `ImpellerSurfaceCreateWrappedFBONew`, calls `SurfaceGLES::WrapFBO`, which builds the color
    attachment descriptor at `sample_count = SampleCount::kCount1` **unconditionally** — there is no
    MSAA branch in this path at all
    [F:engine/src/flutter/impeller/renderer/backend/gles/surface_gles.cc#L14-L48]. Even where the
    GLES backend *can* do MSAA (`GL_EXT_multisampled_render_to_texture` /
    `..._render_to_texture2`, detected in
    [F:engine/src/flutter/impeller/renderer/backend/gles/capabilities_gles.cc#L164-L178]), that
    capability only feeds *offscreen* `EntityPass` targets (`SupportsOffscreenMSAA`/
    `SupportsImplicitResolvingMSAA`, used in
    [F:engine/src/flutter/impeller/renderer/backend/gles/render_pass_gles.cc#L637-L690,L791-L801] and
    [F:engine/src/flutter/impeller/renderer/backend/gles/texture_gles.cc#L55-L79]) — the window FBO
    itself is wrapped 1x, period.

This is the exact, now fully-cited root cause of what the brief calls "our stroked paths alias on
ANGLE/GLES": (1) analytic SDF AA is unreachable through the SDK on *any* backend, and (2) the only
remaining defense, device MSAA, is architecturally absent from Impeller's own GLES window-wrap path
— independent of whether the underlying driver is ANGLE, Mesa, or a real GLES driver. Metal and
Vulkan, by contrast, get real 4x MSAA on the window surface for free, with automatic resolve, the
moment you switch away from the GLES wrapped-FBO surface constructor. See §11 for what this means
for the darwin/Windows-Linux backend question.

## 2. Paths & tessellation

`FillPathSourceGeometry::GetResultMode()` picks `kNonZero`/`kEvenOdd` (stencil-then-cover) unless
`source.IsConvex()`, in which case it tessellates directly with `Tessellator::TessellateConvex`
(no stencil pass needed) [F:engine/src/flutter/impeller/entity/geometry/fill_path_geometry.cc#L44-L66]
[F:engine/src/flutter/impeller/tessellator/tessellator.h#L37-L37,L258-L258]. Non-convex fills go
through the stencil-prep-then-cover two-draw sequence seen in `ClipContents::Render` for clips
(same machinery, §3) — a stencil pass rasterizes the path with `GL_INCR`/parity ops, then a full
cover-rect pass is masked by the stencil. `StrokePathGeometry` converts the stroked outline (caps,
joins, miter limit) into a single triangle-strip vertex arena on the CPU
[F:engine/src/flutter/impeller/entity/geometry/stroke_path_geometry.cc#L1-L60,L130-L420] — this is a
geometric expansion, not a shader technique, and (per §1) carries no coverage AA of its own.

## 3. Clips

`ClipContents::Render` is stencil-based: a stencil-preparation draw (`kStencilNonZeroFill`/
`kStencilEvenOddFill`/`kStencilIncrementAll` depending on geometry mode) followed by a cover-rect
draw gated on the stencil comparison
[F:engine/src/flutter/impeller/entity/contents/clip_contents.cc#L70-L160]. There is a **fast path**:
axis-aligned rect/round-rect clips with a `kDifference` op and `kNormal`/`kPreventOverdraw` geometry
mode skip the stencil entirely and write depth directly
[F:engine/src/flutter/impeller/entity/contents/clip_contents.cc#L84-L92] — this is the
`is_axis_aligned_rect_`/`ClipCoverage::is_difference_or_non_square` optimization
[F:engine/src/flutter/impeller/entity/contents/clip_contents.cc#L41-L64]. `EntityPassClipStack`
tracks every clip recorded in the current pass's stencil so it can be *replayed* when a backdrop
filter or advanced blend forces a pass restart (the stencil buffer must be rebuilt from scratch on
the new pass) [F:engine/src/flutter/impeller/entity/entity_pass_clip_stack.h#L1-L50].

## 4. Text — typographer, glyph atlas

Shaped runs (`TextFrame`, built upstream by Skia's text-shaping, `impeller/display_list/dl_text_impeller.cc`)
are accumulated in a `LazyGlyphAtlas` which defers atlas construction until first paint
[F:engine/src/flutter/impeller/typographer/lazy_glyph_atlas.h#L17-L50]: `AddTextFrame` just queues
`(frame, position, transform, properties)`; `CreateOrGetGlyphAtlas` does the real packing/upload
work, lazily, once per frame if new glyphs were added. There are two atlas textures, never mixed —
`alpha_data_` (`GlyphAtlas::Type::kAlphaBitmap`, 8-bit, backend-chosen Red or Grey channel via
`Capabilities::GetDefaultGlyphAtlasFormat()`) and `color_data_` (`kColorBitmap`, N32 premul, used for
color emoji) [F:engine/src/flutter/impeller/typographer/glyph_atlas.h#L38-L58]. Packing uses a
skyline rectangle packer [F:engine/src/flutter/impeller/typographer/rectangle_packer.cc#L19-L19];
glyph lookup is keyed by `(font, glyph, subpixel position bucket)` — `FrameBounds`/`FontGlyphPair`
carry the atlas rect plus the glyph's local-space bounds so sub-pixel offsets don't require
re-rasterization for every fractional position, only a bucketed set
[F:engine/src/flutter/impeller/typographer/glyph_atlas.h#L20-L30,L130-L160]. Our patch
`0001-rni-text-extensions.patch` adds `ImpellerParagraphStyleSetLetterSpacing/WordSpacing/
SetFontFeature/ClearFontFeatures` to `impeller.cc` [R:engine/impeller-sdk-patches/0001-rni-text-extensions.patch]
— i.e. we had to patch the *interop surface itself* to reach paragraph-style knobs Skia's `txt`
layer already supports, because the SDK didn't expose them.

## 5. Images

Standalone-SDK texture upload is `ImpellerTextureCreateWithContentsNew(context, descriptor,
mapping, release_user_data)` — raw decompressed pixels only, the header explicitly warns "do **not**
supply compressed image data directly (PNG, JPEG...)"
[F:engine/src/flutter/impeller/toolkit/interop/impeller.h#L1320-L1348]; decode is entirely the
embedder's job. Mip generation is controlled by the descriptor's `mip_count`; `BlitPass::GenerateMipmap`
exists for textures that didn't upload their own mip chain, and
`Capabilities::SupportsManuallyMippedTextures()` documents that OpenGL ES 2.0 without
`GL_APPLE_texture_max_level` cannot bound sampling to hand-uploaded mip ranges
[F:engine/src/flutter/impeller/renderer/capabilities.h#L90-L96]. Our `ImageStore.cpp` decodes with
`stb_image` on a detached `std::thread` per image [R:engine/fabric/ImageStore.cpp#L5-L14,L219-L219],
then uploads on the paint thread via that same `ImpellerTextureCreateWithContentsNew` call — matching
the SDK's documented pattern of decode-off-thread + eager-copy-on-call-thread.

## 6. Filters

**Blur**: `GaussianBlurFilterContents` downsamples before blurring (`CalculateScale`/
`CalculateDownsamplePassArgs`, capped at `kMaxSigma = 500`)
[F:engine/src/flutter/impeller/entity/contents/filters/gaussian_blur_filter_contents.cc#L28-L28,L261-L401].
**Our patch `0002-gles-blur-decal-downsample.patch`** changes this: ANGLE-over-Metal exposes no
`GL_EXT_texture_border_clamp`, so the stock `>= 0.5x` downsample (which uses the plain texture
pipeline, clamp-to-edge) smears edge texels into the blur's halo gutter; our patch forces the
GLES "emulate decal in shader" downsample pipeline whenever `tile_mode == kDecal &&
!SupportsDecalSamplerAddressMode()`, with a single bilinear tap substituted for the `>=0.5x` case
[R:engine/impeller-sdk-patches/0002-gles-blur-decal-downsample.patch]. **Backdrop filter**:
`ImpellerDisplayListBuilderSaveLayer(builder, bounds, paint, backdrop)` takes a `backdrop`
`ImpellerImageFilter` argument [F:engine/src/flutter/impeller/toolkit/interop/impeller.h#L1920-L1940]
— the SDK *does* expose it — but **our engine's `SceneGraph.cpp` only ever calls this with
`backdrop = nullptr`** [R:engine/scenegraph/SceneGraph.cpp#L2076-L2096,L2508-L2508]: we use
`SaveLayer` + `ImpellerPaintSetImageFilter`/`SetColorFilter` for *forward* content filters (blur the
layer's own contents) but never for true "blur what's already on screen" backdrop filters. On the
Flutter side, a non-null backdrop forces `requires_readback_` and an extra full-size offscreen copy
[F:engine/src/flutter/impeller/display_list/canvas.cc#L2440-L2510] — we've never exercised that
path. **Mask blur** is a paint-level `mask_blur_descriptor` consumed by `IsCompatibleWithSDFRendering`
(excluded from the SDF fast path, §1) and by `AttemptDrawBlur*` shadow/blur entry points in `canvas.cc`.

## 7. Shaders

`impellerc` (`impeller/compiler`) is Impeller's offline shader compiler: GLSL → SPIR-V → backend
MSL/GLSL/SPIR-V, driven by a `BUILD.gn` shader list, never invoked at app runtime
[F:engine/src/flutter/impeller/compiler/impellerc_main.cc]. Compiled blobs are embedded as
`fml::Mapping` byte arrays (`impeller_entity_shaders_data` etc., passed into
`ContextMTL::Create(Flags{}, CreateShaderLibraryMappings(), ...)`
[F:engine/src/flutter/impeller/toolkit/interop/backend/metal/context_mtl.mm#L13-L30]). **Pipeline
prewarm**: `ContentContext`'s constructor eagerly calls `.CreateDefault(*context_, options)` for
every built-in pipeline variant (glyph atlas, solid fill, texture, gradients, circle, uber-SDF,
complex-RSE, ...) [F:engine/src/flutter/impeller/entity/contents/content_context.cc#L609-L660];
`PipelineVariants::CreateDefault` schedules the default-options PSO compile as `async=true` through
the `PipelineCompileQueue` [F:engine/src/flutter/impeller/entity/contents/content_context.cc#L119-L135],
so default PSOs compile in the background right after context creation and are (usually) ready by
first frame; non-default option combinations (`GetPipeline`) compile synchronously, on demand, the
first time that combination is hit [F:engine/src/flutter/impeller/entity/contents/content_context.cc#L136-L210]
— i.e. an app that hits an unusual blend-mode/stencil-mode/sample-count combination for the first
time can stall on a sync PSO compile mid-frame. `runtime_stage` (`RuntimeStage`, `.fbs` flatbuffer
schema) is the format for user-authored `FragmentProgram`/runtime-effect shaders — these still
cannot be compiled from GLSL source at runtime; they ship as a precompiled IR blob the app loads
(`ImpellerFragmentProgram*` in the interop API, backed by `fragment_program.h`).

## 8. Resource lifetime & memory

`HostBuffer` is the per-frame transient-uniform/vertex arena: ~1 MB blocks, `kHostBufferArenaSize = 4`
— a block is only reused 4 resets after last write, and a `GpuSubmissionTracker` keeps a block alive
past that if its GPU work hasn't completed yet (handles >4 frames in flight safely)
[F:engine/src/flutter/impeller/core/host_buffer.h#L21-L34]. `RenderTargetCache` pools offscreen
`EntityPass` render targets by size/format across frames (`renderer.GetRenderTargetCache()->Start()`
at the top of `SetupRenderPass` [F:engine/src/flutter/impeller/display_list/canvas.cc#L1598-L1600]).
We did not find an engine-wide `OnMemoryPressure`/purge-on-signal hook inside `impeller/renderer`,
`impeller/core`, or `impeller/typographer` at this pin (checked via
`grep -rln "OnMemoryPressure\|PurgeCache\|MemoryPressure\|ClearCache" impeller/{renderer,core,typographer}`
→ no hits); the standalone SDK does not appear to expose a memory-pressure purge API — callers
own texture/atlas lifetime entirely through reference counting (not confirmed exhaustively; this
was a negative grep, not a structural guarantee).

## 9. Device capability probing & driver workarounds

Every backend builds a `Capabilities` object once at context creation by probing the real device:
Metal checks `MTLGPUFamily` membership for framebuffer fetch, compute subgroups, wide-gamut, and BC/
ASTC compression support [F:engine/src/flutter/impeller/renderer/backend/metal/context_mtl.mm#L24-L90];
GLES parses the extension string for `GL_EXT_shader_framebuffer_fetch`,
`GL_EXT_texture_border_clamp`/`GL_NV_texture_border_clamp`, `GL_EXT_multisampled_render_to_texture[2]`,
`GL_OES_element_index_uint`, BC/S3TC/RGTC/BPTC, and separately tags `is_angle_`
[F:engine/src/flutter/impeller/renderer/backend/gles/capabilities_gles.cc#L13-L178]. Vulkan has an
explicit **driver deny-list / workaround table**: `WorkaroundsVK` flags
`slow_primitive_restart_performance`, `batch_submit_command_buffer_timeout`,
`input_attachment_self_dependency_broken`, and `broken_mipmap_generation` (all Adreno 600-800 series,
with specific PowerVR carve-outs), derived from `DriverInfoVK` which enumerates known Adreno/PowerVR
GPU IDs [F:engine/src/flutter/impeller/renderer/backend/vulkan/workarounds_vk.h#L11-L36]
[F:engine/src/flutter/impeller/renderer/backend/vulkan/driver_info_vk.h#L13-L45]. There is no
equivalent named deny-list file for Metal or GLES — those backends gate purely on queryable
feature/extension support, not a hard-coded device blocklist.

## 10. Our engine: what we use vs. bypass/re-implement

We consume Impeller exclusively through the 3133-line standalone C header
[R:engine/third_party/impeller-sdk/include/impeller.h] (`ImpellerDisplayListBuilder*`,
`ImpellerPaint*`, `ImpellerContext*`, `ImpellerSurface*`). Confirmed reachable and actually used by
`SceneGraph.cpp`: `DrawRoundedRect` (tessellated round-rect path, §1/§2 — **not** the SDF path, which
is unreachable regardless) [R:engine/scenegraph/SceneGraph.cpp#L2241-L2241,L2272-L2272],
`DrawTextureRect` (image compositing, including our SVG-raster cache and glyph-cluster blits)
[R:engine/scenegraph/SceneGraph.cpp#L3123-L3123,L3275-L3275,L3392-L3392], `SaveLayer` with
`ImpellerPaintSetColorFilter`/`SetImageFilter` but **always `backdrop = nullptr`**
[R:engine/scenegraph/SceneGraph.cpp#L2076-L2096] (§6), `ClipRect`/`ClipRoundedRect`/`ClipPath`
[R:engine/scenegraph/SceneGraph.cpp#L2213-L2213,L2560-L2563,L2783-L2789], and
`ImpellerGlyphInfoGetGraphemeClusterBounds` for per-glyph hit-testing/selection boxes
(`ClusterBounds` helper) [R:engine/scenegraph/SceneGraph.cpp#L1421-L1423,L1523-L1523]. **Bypassed /
re-implemented outside Impeller**: the entire `supersample_` 4x-offscreen-render-and-downsample path
for SVG subtrees (`paintSvgRootSupersampled`, `paintTreeSupersampled`) is our own compensating
mechanism for §1's GLES-wrapped-FBO MSAA gap — it renders the SVG subtree (or whole tree) into an
N x-sized offscreen via `ImpellerDisplayListBuilderDrawTextureRect`-based composition and box-filters
it down in our own code, entirely outside any Impeller AA mechanism
[R:engine/scenegraph/SceneGraph.cpp#L46-L46,L1997-L2010,L3444-L3564]. Image decode (`stb_image`) and
glyph-cluster bounds math are also ours, not Impeller's (Impeller only rasterizes/uploads what we
hand it).

## 11. Backend switch evaluation: Metal (darwin) / Vulkan (Windows, Linux)

**Darwin: ANGLE-GLES → native Metal via `ImpellerContextCreateMetalNew` +
`ImpellerSurfaceCreateWrappedMetalDrawableNew`.** Per §1, this directly fixes the window-surface AA
gap: `WrapCurrentMetalLayerDrawable` always provisions a 4x MSAA color attachment with automatic
resolve-on-present [F:engine/src/flutter/impeller/renderer/backend/metal/surface_mtl.mm#L49-L89], something the GLES `WrapFBO` path structurally
cannot do. The `0002-gles-blur-decal-downsample.patch` workaround becomes dead code on Metal, since
Metal always reports `SupportsDecalSamplerAddressMode() == true` via
`.SetSupportsDecalSamplerAddressMode(true)`
[F:engine/src/flutter/impeller/renderer/backend/metal/context_mtl.mm#L78-L78] — no border-clamp gap
to emulate. Framebuffer fetch is available on Apple A8+ (`MTLGPUFamilyApple2`+)
[F:engine/src/flutter/impeller/renderer/backend/metal/context_mtl.mm#L24-L31], making advanced blends (screen/multiply/hue/etc., `docs/blending.md`)
cheap instead of requiring the GLES readback-and-blit fallback. **What's lost/changed**: the interop
SDK's *only* offscreen/headless surface constructor is `ImpellerSurfaceCreateWrappedFBONew` (GL FBO)
— there is no Metal-equivalent offscreen-texture-wrapping surface constructor in `impeller.h`
(checked: `grep -n "CreateWrapped" impeller.h` finds only the FBO and Metal-drawable variants,
no generic "wrap a Metal/Vulkan texture as an offscreen surface" entry point) — our `HeadlessSurface.cpp`
(GL FBO readback for CI/golden-image gates) would need a GL-via-ANGLE (or a from-scratch
Metal-offscreen construction bypassing the public surface API) fallback path if we move the *windowed*
path to Metal while keeping headless on GL. `interop/README.md`'s own example set
(`example_mtl.m`) confirms the only documented Metal entry point is drawable-wrapped, window-surface
use [F:engine/src/flutter/impeller/toolkit/interop/README.md#L40-L58].

**Windows/Linux: ANGLE-D3D11 / Mesa-GLES → Vulkan via `ImpellerContextCreateVulkanNew` +
`ImpellerVulkanSwapchain*`.** Same AA win: `SwapchainVK::Create(..., enable_msaa=true)` default
[F:engine/src/flutter/impeller/renderer/backend/vulkan/swapchain/swapchain_vk.h#L36-L40] gives a 4x MSAA swapchain automatically, and it's threaded through
unmodified by the interop wrapper [F:.../interop/backend/vulkan/swapchain_vk.cc#L26-L31]. Vulkan's
`SupportsFramebufferFetch()` depends on `has_framebuffer_fetch_` (device/extension probed, not a
blanket "most Vulkan devices" promise the way `blending.md` states informally)
[F:engine/src/flutter/impeller/renderer/backend/vulkan/capabilities_vk.cc#L745-L748], and
`docs/vulkan_threading.md` documents a mandatory extra thread cost: a concurrent worker pool
(PSO setup / frame workload) plus two dedicated singleton threads, "fence waiter" and "resource
manager", **in addition to** the single render/main thread our engine already runs everything else
on [F:docs/engine/impeller/docs/vulkan_threading.md#L1-L20] — our "ONE thread does polling+build+
submit+present" model is unaffected (Vulkan's extra threads are internal to the backend, invisible
to the interop caller), but CPU/core budgeting on constrained CI machines should account for them.
Linux CI currently runs llvmpipe (software Mesa) — Vulkan on llvmpipe (via `lavapipe`) exists but is
far slower than GL; this needs a real benchmark before committing, not assumed from the docs
(not confirmed: no benchmark run as part of this research pass). `driver_info_vk.h`'s Adreno/PowerVR
deny-list is Android-only in practice (desktop Vulkan ICDs: NVIDIA/AMD/Intel/Mesa RADV/ANV, none of
which appear in `AdrenoGPU`), so the workaround table is unlikely to matter for our desktop targets,
but should be left wired in rather than special-cased out.

**use_sdfs does not change**: switching either backend does **nothing** for analytic AA (§1) — the
interop SDK hard-codes `Flags{}` on every backend's context-creation path, Metal included
[F:.../interop/backend/metal/context_mtl.mm#L26-L30]. The supersample-for-SVG-icons workaround
(§10) is orthogonal to the backend and would need to stay until/unless we patch the SDK to expose
`use_sdfs` — which only gets us SDF AA for circles/round-rects/ovals, not arbitrary stroked SVG
path data (§1's DrawPath carve-out is unconditional, independent of `use_sdfs`).

## 12. Gaps + work items (ranked by risk)

1. **[Wrong pixels, high]** GLES window surface has no MSAA by construction (§1) and SDF AA is
   unreachable on every backend (§1) — any stroked path not routed through our supersample hack
   aliases on darwin/Windows today.
   - *Build*: either extend the supersample hack to all stroked-path draws, or do the Metal/Vulkan
     switch (§11), which fixes it at the surface level for free.
   - *Model*: `SurfaceMTL::WrapCurrentMetalLayerDrawable` [F:engine/src/flutter/impeller/renderer/backend/metal/surface_mtl.mm#L49-L89].
   - *Gate*: render a 2px stroked diagonal line off any supersample path; sample the 1px transition
     band across the stroke edge; require ≥3 distinct partial-coverage alpha values.
   - *Mutant*: force `supersampleRnsvg=0` without the backend switch — gate must fail (binary edge).

2. **[Wrong pixels, medium]** `0002-gles-blur-decal-downsample.patch` is a narrow hand patch keyed to
   `MakeDownsampleSubpass`'s current shape; a future pin bump could silently break its hook.
   - *Build*: CI check diffing the patch's hunk context against the vendored source on every SDK
     rebuild, failing loudly instead of silently no-opping.
   - *Gate*: rebuild from a bumped pin, run a drop-shadow fixture on GLES, assert no edge-texel
     smear (gutter alpha below threshold, not clamp-smear plateau).
   - *Mutant*: revert the patch, rebuild, rerun — gate must fail (visible smear).

3. **[Jank, medium]** Non-default pipeline-option combos compile synchronously on first use
   (§7, `GetPipeline` `async=false`) — an unseen blend/stencil combo can stall mid-frame.
   - *Build*: a startup pipeline-warm tour exercising every (blend_mode, stencil_mode, clip_mode)
     combo `SceneGraph.cpp` can produce, off the critical path.
   - *Model*: `ContentContext`'s default-pipeline prewarm loop [F:.../content_context.cc#L609-L660].
   - *Gate*: instrument `pass.Draw()` wall time; after warm-up, first occurrence of any
     (blend_mode, stencil_mode) pair must stay under a profiled baseline (e.g. 4ms worst-GPU).
   - *Mutant*: skip the warm tour, trigger an unwarmed blend mode (e.g. first `Multiply`) — gate
     must catch the stall.

4. **[Missed feature, low-medium]** Real backdrop filters are untested — `SaveLayer`'s `backdrop`
   param is always `nullptr` today (§6, §10); a future "blur behind this card" ask hits an entirely
   unexercised path (`requires_readback_`, extra offscreen copy, clip-stack replay, §6).
   - *Build*: a minimal blur-behind-card fixture using a non-null `backdrop` `ImpellerImageFilter`.
   - *Model*: `Canvas::ApplyBackdropFilter`'s `requires_readback_` branch [F:engine/src/flutter/impeller/display_list/canvas.cc#L2440-L2510].
   - *Gate*: pixels behind the card show lower local variance (blurred) vs. a no-filter control;
     pixels outside the card bounds are unchanged.
   - *Mutant*: pass `backdrop=nullptr` (today's code) — gate must fail (no blur).

5. **[Memory, low]** No confirmed memory-pressure purge hook in the standalone SDK (§8); glyph/
   texture caches could grow unbounded across a long-running session or CI sweep.
   - *Build*: confirm no such hook exists (beyond this pass's grep), or add our own periodic
     atlas/texture-cache cap with manual eviction.
   - *Gate*: cycle through >N distinct glyphs/fonts/images in one long session; steady-state GPU
     memory must plateau once the visible working set stabilizes, not grow linearly with time.
   - *Mutant*: disable our eviction — gate must fail (unbounded growth).

