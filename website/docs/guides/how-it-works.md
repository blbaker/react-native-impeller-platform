---
title: How it works
---

# How it works

## The render path

React Native's Fabric renderer owns the component tree the same way it does
on iOS and Android. On iOS and Android, Fabric hands each mutation to a
native view hierarchy. Here, Fabric hands each mutation to this engine,
which turns it into a scene graph node and paints the scene graph with
Impeller.

The engine uses Flutter's thread model for Impeller. React Native's
contracts stay the same beneath it:

| Role | What runs there |
|---|---|
| JS thread | Hermes, React, Fabric commit. An immutable shadow-tree revision comes out the other side, the same as on iOS and Android. |
| Platform thread | Receives OS events, mounts the committed revision into the scene graph, and schedules frames. |
| Raster thread | Walks the scene graph into an Impeller display list and presents it to the GPU surface for the current OS. |

That three-thread split (JS, platform, raster) mirrors Flutter's UI,
platform, and raster roles. For file and line citations of this thread
model in both Flutter's source and the engine, see
[`SPEC.md`](https://github.com/blbaker/react-native-impeller-platform/blob/main/docs/eng/flutter-parity/SPEC.md)
in [`docs/eng/flutter-parity/`](https://github.com/blbaker/react-native-impeller-platform/tree/main/docs/eng/flutter-parity).
[`DIAGRAMS.md`](https://github.com/blbaker/react-native-impeller-platform/blob/main/docs/eng/flutter-parity/DIAGRAMS.md)
has the thread-model and backend diagrams.

## Backends by OS

This engine targets the same backend Impeller uses for each OS:

| OS | Backend |
|---|---|
| macOS | ANGLE over Metal today. Native Metal (4x MSAA) lands as the engine moves off ANGLE on Apple platforms. Pass `--backend gles` to keep the ANGLE path. |
| Linux | OpenGL ES over EGL, through Mesa. CI renders with the `llvmpipe` software rasterizer, since there's no GPU requirement for the gates. |
| Windows | OpenGL ES over ANGLE on Direct3D 11. |

Metal and Vulkan backends get anti-aliasing from the surface's MSAA.
The GL path (Linux, Windows, and macOS until native Metal lands) has no
surface-level AA, so stroked SVG icons use a supersample-then-downsample
pass instead: render the icon at 4x into an offscreen texture, then
composite it down with a linear filter. See
[Styling](./styling) for where that applies.

## Engine binary resolution

The `react-native-impeller-platform` package doesn't bundle a C++ binary.
Each supported platform ships a
`@blbaker/react-native-impeller-platform-engine-OS-CPU` package as an
optional dependency, where `OS` and `CPU` identify the operating system
and CPU architecture, and the JS package resolves the right one at
runtime:

1. `IMPELLER_ENGINE_BINARY`, if set, wins outright. This is for engine
   development, not for consuming the package.
2. Otherwise, the resolver looks for the matching engine package starting
   from its install location, so an installed package and a packed
   tarball both work the same way.
3. Under `npm link` or a `file:` dependency, the resolver also checks the
   consumer's `node_modules` and, as a last resort, the linked source
   checkout's `packages-engine/` build output.
4. If nothing resolves, the error names the exact package it expected and
   every path it looked in.
5. If an engine package resolves but its version doesn't match the host
   package exactly, the resolver refuses it. The engine exposes a C ABI
   that isn't stable across versions, so a mismatch triggers a hard
   failure instead of a warning.

For more information about the full set of real error messages, see
[Debugging](./debugging).

## Metro and the CLI

Running `npx react-native init-impeller` scaffolds an `impeller/` folder
into your app and wraps `metro.config.js` with `withImpeller`, which
teaches Metro about the `impeller` platform. Running
`npx react-native run-impeller` bundles the app with Metro for that
platform and launches the resolved engine binary with the bundle's
absolute path. The engine requires that absolute path and never falls
back to a bundle found by guessing a working directory. An invalid path
produces an error instead of a stale render. For more information about
the available flags, see the [CLI reference](../reference/cli).

## What's still open

This project tracks a published gap list against Flutter's Impeller
integration. As of this writing, the two items with the highest
production risk are an Android Vulkan swapchain that doesn't recreate
itself when it goes out of date, and no explicit vsync pacing on most
platforms yet, both tracked in
[`SPEC.md`](https://github.com/blbaker/react-native-impeller-platform/blob/main/docs/eng/flutter-parity/SPEC.md#4-gaps-ranked-by-production-risk).
