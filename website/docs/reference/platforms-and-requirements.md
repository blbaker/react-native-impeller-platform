---
title: Platforms and requirements
---

# Platforms and requirements

The following table lists the engine package, rendering backend, and
support status for each platform:

| Platform | Engine package | Backend | Status |
|---|---|---|---|
| macOS (arm64) | `@blbaker/react-native-impeller-platform-engine-darwin-arm64` | Native Metal (4x MSAA); ANGLE/GLES with `--backend gles` | Builds and renders |
| Linux (x64) | `@blbaker/react-native-impeller-platform-engine-linux-x64` | OpenGL ES over EGL (Mesa) | Builds and renders |
| Windows (x64) | `@blbaker/react-native-impeller-platform-engine-win32-x64` | OpenGL ES over ANGLE (Direct3D 11) | Builds and renders |
| Android (arm64) | none yet | Vulkan, with a GLES fallback for known-bad drivers | Experimental: an embeddable view that draws Impeller display lists into a `SurfaceView`. No React Native runtime on it yet. |
| iOS | none | n/a | Not supported yet. Flutter uses Metal there. An iOS host is future work. |

A platform is listed as supported only after its engine package actually
exists and renders correctly outside this repository. npm silently skips
a missing optional dependency and exits `0`. If the platform isn't ready,
you get a clean install with no engine, and then a runtime error telling
you to install a package that doesn't exist.

## Linux (x64)

This platform renders through OpenGL ES over EGL, using Mesa. There's no
GPU requirement to run the gates: CI and local headless runs use Mesa's
`llvmpipe` software rasterizer, which is what `tools/ci-headless.sh` was
written to prove works at all.

## macOS (arm64)

This platform renders through ANGLE over Metal today. Windowed gates need
a real display. Headless gates run anywhere, including CI. Building the
engine from source needs full Xcode instead of only the Command Line
Tools.

## Windows (x64)

This platform renders through OpenGL ES over ANGLE on Direct3D 11.
Building the engine from source shells out to `cmd.exe` and MSVC, so it
needs to run somewhere that can reach the Windows toolchain. From WSL,
that means the Windows toolchain needs to be on `PATH`.

## Android (arm64): experimental

This experimental platform is an embeddable view that draws Impeller
display lists into a `SurfaceView`, targeting Vulkan with a GLES fallback
for known-bad drivers, the same split Flutter uses on Android. No React
Native runtime runs on it yet, so an Android app using this platform
still runs stock React Native underneath it. Only the view itself renders
through Impeller. There's no published engine package for Android yet.

## iOS: not supported yet

Flutter renders through Metal directly on iOS. An iOS host for this
engine is future work. Nothing is published for it today.

## Build an engine for any of these platforms

For more information about the setup and build commands, see
[Building the engine from source](../guides/building-the-engine-from-source).
