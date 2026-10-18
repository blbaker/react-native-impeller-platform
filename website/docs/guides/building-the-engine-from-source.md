---
title: Building the engine from source
---

# Building the engine from source

You only need this if you're developing the engine itself. If you're
consuming the published package in an app, npm install already gives you
a prebuilt engine binary. For more information, see
[Get started](../getting-started).

## Requirements

Building the engine requires Node 20 or later, CMake, and a C++ compiler
toolchain for your platform. macOS additionally needs full Xcode instead
of only the Command Line Tools.

## Fetch GLFW

GLFW is fetched by a script, not committed to the repository. Before you
build the engine for the first time from a new clone, run the following
command:

```bash
bash tools/glfw-fetch.sh
```

Skipping this step is what produces the "GLFW not found" CMake error. For
more information, see
[Debugging](./debugging#glfw-not-found-during-the-cmake-configure-step).

## Build the engine

To build the engine binary for your platform, run the following command:

```bash
bash tools/engine-build.sh PLATFORM ARCH
```

Replace `PLATFORM` and `ARCH` with your operating system and CPU
architecture. The following examples show the exact values for each
supported platform:

- Linux: `bash tools/engine-build.sh linux x64`
- macOS (Apple Silicon): `bash tools/engine-build.sh darwin arm64`
- Windows (from a shell with `cmd.exe` on `PATH`, including WSL with the
  Windows toolchain reachable): `bash tools/engine-build.sh win32 x64`

The first build compiles Hermes from source at the exact tag React Native
pins, and fetches the pinned Impeller SDK, so expect it to take a while.
Later builds reuse that result. The output is staged under
`packages-engine/engine-PLATFORM-ARCH/bin/`, using the same `PLATFORM` and
`ARCH` values.

## Platform notes

The engine renders differently on each platform, as the following list
describes:

- **Linux** renders through Mesa's software rasterizer (`llvmpipe`) in a
  headless or CI environment, so there's no GPU requirement to run the
  gates.
- **macOS** renders through ANGLE over Metal today. Windowed gates need a
  real display. Headless gates run anywhere, including CI.
- **Windows** renders through ANGLE over Direct3D 11. The build script
  shells out to `cmd.exe` and MSVC, so it needs to run somewhere that can
  reach the Windows toolchain.

## Point your app at the binary you built

To point the resolver at the engine you built, run the following command:

```bash
export IMPELLER_ENGINE_BINARY=/path/to/rn-impeller
```

The `run-impeller` command checks this environment variable before
resolving the installed engine package. For more information, see
[Use a locally built engine](../getting-started#optional-use-a-locally-built-engine).

## Run the gates

After you build the engine,
[Contributing and releasing](../contributing-and-releasing#run-the-gates)
has the full gate and mutation-verify workflow used to check a change.
