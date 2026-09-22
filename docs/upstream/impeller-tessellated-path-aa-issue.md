# Impeller: builder-composed (tessellated) paths render with no edge anti-aliasing on the GLES/OpenGL backend

## Summary

On the Impeller **OpenGL ES** backend, a path built from cubic/line
primitives (`ImpellerPathBuilderMoveTo` / `LineTo` / `CubicCurveTo`) renders
with **no edge anti-aliasing** — hard, binary black/white pixels at every
edge. The *identical* shape built with the analytic `ImpellerPathBuilderAddOval`
fast path **is** anti-aliased. Same `ImpellerPaint`, same `ImpellerDisplayList`,
same `ImpellerSurface`, same radius. The only difference is which builder
primitive composed the path.

This makes every arbitrary vector path (SVG `d` strings, icon sets, any
tessellated geometry) look aliased, while circles/rounded-rects that hit the
analytic fast path look crisp — a visible quality split within one frame.

## Repro (self-contained, C API + GLES only)

`impeller_tessellated_aa_repro.cpp` (attached): one display list, one paint,
one surface. Left circle via `AddOval`, right circle as four kKappa cubic
Beziers. Both radius 60, both `kImpellerDrawStyleFill`, opaque black on white.

```
GL_RENDERER=llvmpipe (LLVM 20.1.2, 256 bits)
GL_EXT_multisampled_render_to_texture=ABSENT

Same paint, same surface, same radius=60 circle:
  AddOval    11516 px | 11120 pure /   364 partial =   3.2% partial | 50 distinct
  cubics     11272 px | 11272 pure /     0 partial =   0.0% partial |  1 distinct
```

`partial` = pixels with intermediate luminance (9..246); `distinct` = distinct
luminance values along the rim. The AddOval rim carries 50 grey levels (real
coverage AA); the cubic rim carries exactly 1 (pure black) — a hard-clipped
edge. Visual: left rim smooth, right rim visibly stair-stepped.

## What we ruled out (each with a measured arm)

- **Not a paint setting.** The C API has 11 `ImpellerPaintSet*` entry points
  (color, blend, draw style, cap/join/width/miter, color/image/mask filter,
  color source). None toggles anti-aliasing — there is no bit to set.
- **Not the wrapped surface's sample count.** Handing Impeller a 4x MSAA
  renderbuffer FBO produced byte-identical output to a single-sample FBO;
  Impeller resolves AA into its own offscreen (`CreateMSAATexture`) and ignores
  the sample count of the target it is handed. A real 4x default framebuffer
  (`GLFW_SAMPLES=4`, `GL_SAMPLES` confirmed 4 on the live FB) also changed the
  cubic route by zero intermediate pixels.
- **Not curves specifically.** A straight-line triangle (`LineTo` only) is also
  0.0% partial — any builder-tessellated path aliases, not just cubics.
- **Not a client SVG parser.** Direct C-API builder calls with no string
  parsing reproduce it identically.

## Suspected mechanism

Impeller appears to AA analytic primitives (`AddOval` / `AddRoundedRect`) via
per-fragment coverage in the shader, but AA the general tessellation path
through an MSAA offscreen. Where `GL_EXT_multisampled_render_to_texture` is
absent (llvmpipe here), the tessellated route falls back to no coverage AA at
all. **Open question for maintainers:** on a hardware GLES/Metal GPU where the
MSAA offscreen is available, does the cubic route antialias? If it is
MSAA-offscreen-dependent, the fix is to guarantee that offscreen (or add
analytic coverage AA to the tessellation path) so tessellated paths match the
analytic fast path.

## Environment
- Impeller SHA: `114eb184d66d7ca136d89eb8ec09f61aff265062`
- Backend: OpenGL ES (`ImpellerContextCreateOpenGLESNew`)
- `GL_RENDERER=llvmpipe (LLVM 20.1.2, 256 bits)`, GLES 3.2 Mesa 25.2.8
- `GL_MAX_SAMPLES=4`, `GL_EXT_multisampled_render_to_texture` absent
