---
title: Introduction
---

# Introduction

react-native-impeller-platform is an out-of-tree React Native platform. Its
renderer is [Impeller](https://github.com/flutter/engine/tree/main/impeller),
Flutter's graphics engine, not Skia and not a native UI toolkit. React
components mount through Fabric into a scene graph that Impeller paints.
There is no DOM, no native view hierarchy, and no per-platform UI toolkit
underneath it.

## Why this exists

React Native creates matching native views for your components on iOS and
Android. Every other platform needs someone to build that layer. React
Native's own docs list partner platforms for macOS and Windows. For Linux
they point to a renderer built on Skia whose README still calls it a proof
of concept, with no commit since March 2023.

This project started as a Skia-based renderer for Linux, macOS, and Windows.
The rendering worked, but the packaging didn't, and none of it was reusable
the way it needed to be.

Impeller turned out to be a better fit. Flutter built it to fix the problems
it had with Skia, and it's now the only renderer Flutter uses on iOS and the
default on Android, macOS, Linux, and Windows. A few things made it the right
choice here:

- Google publishes a prebuilt Impeller SDK for every Flutter commit, for
  macOS, Linux, Windows, and Android.
- Text layout and shaping come with the SDK.
- Shaders are compiled when the engine is built, so nothing compiles at
  runtime.
- Impeller draws from a display list, and this engine builds one from React
  Native's view tree every frame.

Impeller needs a GPU, and its own README says it will likely never get a
software renderer. Running tests on a GPU machine for every commit wasn't an
option, so the first commit in this repo checked that Impeller renders on
Linux with no GPU at all, through Mesa's `llvmpipe`. That check still runs as
`tools/ci-headless.sh`.

From there the engine follows how Flutter runs Impeller: React Native's JS
thread takes the place of Flutter's UI thread, a separate raster thread does
the drawing, and each OS gets the graphics backend Flutter ships there. The
platform installs next to stock React Native, the same way React Native for
Windows does. It's already rendering a React Native app in daily use.

## Status

Pre-release, and honest about it. The rendering, the JS to native module
seam, and the packaging are gated by pixel tests on every commit, but the
API surface is small and the published platform list is short. Every
package is versioned `0.1.0`. Expect breaking changes between releases until
a `1.0.0` is tagged.

## Supported platforms

| Platform | Engine package | Backend | Status |
|---|---|---|---|
| macOS (arm64) | `@blbaker/react-native-impeller-platform-engine-darwin-arm64` | Native Metal (4x MSAA); ANGLE/GLES with `--backend gles` | Builds and renders |
| Linux (x64) | `@blbaker/react-native-impeller-platform-engine-linux-x64` | OpenGL ES over EGL (Mesa) | Builds and renders |
| Windows (x64) | `@blbaker/react-native-impeller-platform-engine-win32-x64` | OpenGL ES over ANGLE (Direct3D 11) | Builds and renders |
| Android (arm64) | none yet | Vulkan, with a GLES fallback for known-bad drivers | Experimental: an embeddable view that draws Impeller display lists into a `SurfaceView`. No React Native runtime on it yet. |
| iOS | none | n/a | Not supported yet. Flutter uses Metal there; an iOS host is future work. |

A platform is listed as supported only once its engine package actually
exists and renders correctly outside this repo. npm silently skips a missing
optional dependency and exits `0`, so declaring a platform that isn't ready
would give you a clean install with no engine, and then a runtime error
telling you to install a package that doesn't exist.

Continue to [Getting started](./getting-started) to install the package, or
read [How it works](./guides/how-it-works) for the architecture underneath it.
