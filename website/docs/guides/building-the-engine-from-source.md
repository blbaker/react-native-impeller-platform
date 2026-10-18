---
title: Building the engine from source
---

# Building the engine from source

You only need this if you're developing the engine itself. If you're
consuming the published package in an app, `npm install` already gives you
a prebuilt engine binary; see [Getting started](../getting-started).

## Requirements

Node 20 or later, CMake, and a C++ compiler toolchain for your platform.
macOS additionally needs full Xcode, not just the Command Line Tools.

## Fetch GLFW

GLFW is fetched by a script, not committed to the repository. Run this once
per clone before the first engine build:

```bash
bash tools/glfw-fetch.sh
```

Skipping this step is what produces the "GLFW not found" CMake error; see
[Debugging](./debugging#glfw-not-found-during-the-cmake-configure-step).

## Build the engine

```bash
bash tools/engine-build.sh <platform> <arch>
```

- Linux: `bash tools/engine-build.sh linux x64`
- macOS (Apple Silicon): `bash tools/engine-build.sh darwin arm64`
- Windows (from a shell with `cmd.exe` on `PATH`, including WSL with the
  Windows toolchain reachable): `bash tools/engine-build.sh win32 x64`

The first build compiles Hermes from source at the exact tag React Native
pins, and fetches the pinned Impeller SDK; expect it to take a while. Later
builds reuse that result. The output is staged under
`packages-engine/engine-<platform>-<arch>/bin/`.

## Platform notes

- **Linux** renders through Mesa's software rasterizer (`llvmpipe`) in a
  headless or CI environment, so there's no GPU requirement to run the
  gates.
- **macOS** renders through ANGLE over Metal today. Windowed gates need a
  real display; headless gates run anywhere, including CI.
- **Windows** renders through ANGLE over Direct3D 11. The build script
  shells out to `cmd.exe` and MSVC, so it needs to run somewhere that can
  reach the Windows toolchain.

## Point your app at the binary you just built

```bash
export IMPELLER_ENGINE_BINARY=/path/to/rn-impeller
```

`run-impeller` checks this environment variable before resolving the
installed engine package. See
[Using a locally built engine](../getting-started#using-a-locally-built-engine).

## Running the gates

Once the engine is built, [Contributing and releasing](../contributing-and-releasing#running-the-gates)
has the full gate and mutation-verify workflow used to check a change.
