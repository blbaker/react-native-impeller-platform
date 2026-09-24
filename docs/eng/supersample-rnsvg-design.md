# --supersample-rnsvg N — design (item 2)

Feasibility VALIDATED at the C-API level (symbols confirmed present in
`engine/third_party/impeller-sdk/include/impeller.h`). Not yet built.

## Why
Impeller gives stroked tessellated paths NO edge coverage AA (Mac Metal: 2
luminance levels, 0% partial — see `docs/upstream/impeller-tessellated-path-aa-issue.md`).
Until upstream adds analytic coverage AA, supersample-then-downsample is the
client-side fix: render the icon at N× into an offscreen, then composite it
down with a linear filter. The box filter of the downsample synthesises the
partial-coverage edge pixels Impeller refuses to emit.

## Mechanism (GL / ANGLE path — covers Linux surfaceless AND darwin ANGLE-Metal)
1. Detect an `RNSVGSvgView` subtree root in `paintNode` (node.isSvgRoot).
2. When `supersample_ > 0`, instead of drawing the subtree into the main
   builder in place:
   a. Create a GL texture + FBO sized `ceil(w*N) x ceil(h*N)` in Impeller's OWN
      GL context (the eglContext_ HeadlessSurface/GlfwSurface already made
      current — same sharegroup, which is the documented requirement for
      `ImpellerTextureCreateWithOpenGLTextureHandleNew`).
   b. Wrap the FBO: `ImpellerSurfaceCreateWrappedFBONew(context, fbo, fmt, {W,H})`.
   c. Build a fresh display list for JUST this subtree, pre-scaled by N
      (Translate/Scale N), and `ImpellerSurfaceDrawDisplayList` it into the
      offscreen.
   d. Adopt the FBO's color texture: `ImpellerTextureCreateWithOpenGLTextureHandleNew`
      (ownership transfers to Impeller — do NOT glDeleteTextures it ourselves).
   e. Back on the MAIN builder: `ImpellerDisplayListBuilderDrawTextureRect`
      src={0,0,W,H} dst={x,y,w,h}, sampling=LINEAR. The min-filter downsample
      is the anti-aliasing.

## ⚠️ Hazards the build must handle (documented in the C API)
- DrawDisplayList "will not make an effort to preserve OpenGL state" — render
  the offscreen BEFORE touching the main surface's bindings, or save/restore GL
  viewport + FBO + texture bindings around it.
- Texture handle ownership TRANSFERS to Impeller. The FBO stays ours; the color
  texture does not. Cache must hold the ImpellerTexture, not re-adopt a handle.
- Darwin is ANGLE-over-Metal (see HeadlessSurface `EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE`),
  so the GL texture-handle path is valid there too — no separate Metal-drawable
  path needed for the offscreen.

## Flag
`--supersample-rnsvg N` in main.cpp arg parse -> FabricHost/SceneGraph field.
Default 4 on darwin, 0 (disabled) elsewhere. 0 => the exact current in-place
path (zero behavioural change when off — this is the mutant-N=1 control's
sibling).

## Per-icon texture cache (build in from the start — cheap)
Key = hash(svgD paths in subtree) + rounded pixel size (w,h) + resolved color(s)
+ N. Same key => reuse the ImpellerTexture, skip re-rasterize. This is what
makes the frame-time cost acceptable on icon-heavy screens (Board/Settings);
macOS tester takes the stopwatch. Invalidate on prop/size change (key changes
naturally). Bound the cache (LRU, ~256 entries) so a scrolling icon list
doesn't leak.

## Gate (tools/ci-supersample.sh)
Fixture: one stroked chevron (tessellated path, stroke 1.8) in an RNSVGSvgView.
- Render at N=0 -> count partial-luminance edge pixels (9..246) with --ink-band.
- Render at N=4 -> partial count must JUMP by a large margin (binary edge -> AA'd).
- Assert distinct-luminance-levels goes from ~2 to many.

## Mutation (tools/mutation-verify-supersample.sh)
- M1: force N=1 in the offscreen (no supersample, just an offscreen round-trip).
  Partial count must NOT jump -> gate MUST fail. Proves the gate measures the
  supersample, not merely "an offscreen was used".
- M2: skip the DrawTextureRect composite (offscreen rendered, never drawn back).
  The icon vanishes -> gate fails on zero ink. Proves the composite is real.
