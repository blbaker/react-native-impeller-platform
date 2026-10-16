# How the Flutter/Impeller research was done

Date: 2026-10-14. Reproducible from this repo plus two local checkouts.

## Sources
- **flutter/flutter at `114eb184d66d7ca136d89eb8ec09f61aff265062` (2026-08-09).** This is the exact commit our
  custom Impeller SDK is built from (`engine/IMPELLER_SHA`). It was read from the full checkout at
  `~/projects/_ref/sc32/flutter`, which `tools/impeller-sdk-custom-build.sh` creates. Two interop files carry our local
  patches there, so they were read with `git show HEAD:<path>`.
- **flutter/flutter master `200fdfbd` (2026-10-14).** A sparse clone at `~/projects/_ref/flutter`, used to
  check drift. The Impeller C API (`impeller/toolkit/interop/impeller.h`) is identical to the pin: 176
  functions, none added or removed (`research-notes.md`).
- **React Native 0.86.2,** as vendored in `engine/rn/node_modules/react-native`.
- **Our engine at `840961d`** (feat/native-anim-transform, what the Mac ran on 2026-10-14).
- **GitHub issues/search API** for open upstream issues. Only URLs that were actually fetched are cited.

## Process
1. Four research passes ran in parallel, one per subsystem, all following the same brief: frame pipeline and threads, Impeller internals, platform embedding, and
   quality engineering. Each wrote one appendix with `[F:path:L]` / `[R:path:L]` / `[RN:path:L]` citations.
2. Load-bearing claims were re-read by hand against the source. There were 22, including: raster cache off under
   Impeller, interop `Flags{}` on all three backends, the GL `WrapFBO` 1x vs the Metal 4x MSAA drawable,
   Flutter desktop GL using `WrapFBO`, the Windows ANGLE-D3D11 and Linux GLES-only embedders, the
   NativeAnimated JS-queue hop, image decode clamping, swapchain retry, and Metal decal support. One line
   number had drifted by 4 lines and was corrected.
3. A worker had cited the brief's own description of OUR Windows backend as evidence about
   Flutter's. That claim was re-verified from Flutter source (`shell/platform/windows/egl/manager.cc:69`)
   before it was used.
4. Every citation was machine-checked with `tools/flutter-parity-cite-audit.py audit`. Each file must exist at the
   pinned commit and each line range must be in bounds. Result: 335 resolvable citations. The 2 that were not
   resolvable are a legend line and a toolchain header outside the repo.
5. The spec (`../SPEC.md`) was written from the verified facts.

## Limits stated in the spec
These are open measurements, not conclusions:
- whether ANGLE-Metal exposes `GL_EXT_multisampled_render_to_texture`
- lavapipe performance for a Vulkan CI lane
- a Hermes idle-time GC hint
- whether RN's `LayoutAnimationKeyFrameManager` is compiled into our build
