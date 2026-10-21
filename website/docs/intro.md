---
title: Introduction
---

# Introduction

The react-native-impeller-platform package is an out-of-tree React Native
platform. Its renderer is [Impeller](https://github.com/flutter/engine/tree/main/impeller),
Flutter's graphics engine. Impeller isn't Skia or a native UI toolkit.
React components mount through Fabric into a scene graph that Impeller
paints. There's no DOM, native view hierarchy, or per-platform UI toolkit
underneath it.

For the background, read [Why I put React Native on Impeller](https://bbaker.dev/blog/why-react-native-on-impeller).

## React Native beyond iOS and Android

React Native creates matching native views for your components on iOS and
Android. Every other platform needs someone to build that layer. React
Native's docs list partner platforms for macOS and Windows. For Linux
they point to a renderer built on Skia whose README still calls it a proof
of concept, with no commit since March 2023.

## Why Impeller

Flutter built Impeller to fix problems it had with Skia. Impeller is now
the only renderer Flutter uses on iOS and the default renderer on
Android, macOS, Linux, and Windows. Impeller has the following
properties:

- Google publishes a prebuilt Impeller SDK for every Flutter commit, for
  macOS, Linux, Windows, and Android.
- Text layout and shaping come with the SDK.
- Shaders are compiled when the engine is built, so nothing compiles at
  runtime.
- Impeller draws from a display list, and this engine builds one from
  React Native's view tree every frame.

Impeller needs a GPU, and its README says a software renderer probably
isn't coming. The `tools/ci-headless.sh` check confirms that Impeller
renders on Linux with no GPU, through Mesa's `llvmpipe`, so the gates
don't need a GPU machine for every commit.

The engine follows Flutter's thread model for Impeller: React Native's
JS thread takes the place of Flutter's UI thread, a separate raster
thread does the drawing, and each OS gets the graphics backend Flutter
ships there. The platform installs next to stock React Native, the same
way React Native for Windows does. It renders a React Native app in
daily use.

## Status

This project is pre-release software. The rendering, the JS to native
module seam, and the packaging are gated by pixel tests on every commit,
but the API surface is small and the published platform list is short.
Every package is versioned `0.1.0`. Expect breaking changes between
releases until a `1.0.0` is tagged.

## Supported platforms

The following table lists the engine package, rendering backend, and
support status for each platform:

| Platform | Engine package | Backend | Status |
|---|---|---|---|
| macOS (arm64) | `@blbaker/react-native-impeller-platform-engine-darwin-arm64` | Native Metal (4x MSAA); ANGLE/GLES with `--backend gles` | Builds and renders |
| Linux (x64) | `@blbaker/react-native-impeller-platform-engine-linux-x64` | OpenGL ES over EGL (Mesa) | Builds and renders |
| Windows (x64) | `@blbaker/react-native-impeller-platform-engine-win32-x64` | OpenGL ES over ANGLE (Direct3D 11) | Builds and renders |
| Android (arm64) | none yet | Vulkan, with a GLES fallback for known-bad drivers | Experimental: an embeddable view that draws Impeller display lists into a `SurfaceView`. No React Native runtime on it yet. |
| iOS | none | n/a | Not supported yet. Flutter uses Metal there. An iOS host is future work. |

A platform is listed as supported only after its engine package exists
and renders correctly outside this repository. npm silently skips a
missing optional dependency and exits `0`. If the platform isn't ready,
you get a clean install with no engine, and then a runtime error telling
you to install a package that doesn't exist.

## What's next

- To install the package, see [Get started](./getting-started).
- To learn about the architecture, see [How it works](./guides/how-it-works).
