---
title: Debugging
---

# Debugging

The resolver and build scripts name the exact problem when something
goes wrong. The following sections list the real messages you see, and
what each one means.

## GLFW not found during the CMake configure step

GLFW is fetched by a script, not committed to the repository. A clean
clone doesn't build with `tools/engine-build.sh` alone. To fetch GLFW
first, run the following command:

```bash
bash tools/glfw-fetch.sh
```

Then build the engine as usual. For more information, see
[Build the engine from source](./building-the-engine-from-source).

## Unsupported platform or architecture

Your platform and CPU combination isn't in the resolver's supported set
(currently `linux-x64`, `win32-x64`, and `darwin-arm64`). The error message
looks like the following, where `PLATFORM` and `ARCH` identify your
operating system and CPU:

```
react-native-impeller-platform does not support PLATFORM-ARCH yet.
```

The message includes a link to track or request support for your
platform. Setting `IMPELLER_ENGINE_BINARY` doesn't help here, because
there's no published engine for your triple to point at.

## Missing engine package

The resolver looked for the per-platform engine package and didn't find
it. The error lists every path it checked. This usually means the
optional dependency didn't install, most often because `npm install` ran
with `--no-optional`, or because an engine package was published after
you last ran `npm install`. To install it explicitly, run the following
command:

```bash
npm install @blbaker/react-native-impeller-platform-engine-PLATFORM-ARCH@VERSION
```

Replace `PLATFORM-ARCH` with your operating system and CPU, for example
`linux-x64`, and `VERSION` with the version of `react-native-impeller-platform`
that your app installed.

If you're working from a linked source checkout (`npm link` or `file:`)
instead of a normal install, see the next section.

## Engine version mismatch

The error message looks like the following:

```
Engine version mismatch: @blbaker/react-native-impeller-platform-engine-linux-x64@0.0.2 is installed
but react-native-impeller-platform@0.1.0 requires exactly 0.1.0.
```

The host package and every engine package ship at the same version in
lockstep, because the engine exposes a C ABI that isn't stable across
versions. A mismatch triggers a hard failure instead of a warning,
because a mixed pair crashes at runtime in ways that look like renderer
bugs. Install the matching version named in the error.

## Engine package installed without a binary

If you're consuming a normal install, the package is corrupt. Reinstall
it. If you're working from a linked source checkout, this is expected
until you build the engine yourself. To build it, run the following
command:

```bash
bash tools/engine-build.sh PLATFORM ARCH
```

Replace `PLATFORM` and `ARCH` with your operating system and CPU, for
example `linux x64`. The `packages-engine/*/bin` directory is
intentionally left out of git, so a checkout with no build has a
`package.json` file but no binary.

## A missing file at the configured engine binary path

The `IMPELLER_ENGINE_BINARY` environment variable is pointed at a path
that doesn't exist. Unset it to fall back to the installed engine
package, or point it at a binary you built yourself.

## Platform not in the install list

npm silently skips a missing optional dependency and exits `0`. If your
platform isn't in the table on the
[Platforms and requirements](../reference/platforms-and-requirements) page,
installing doesn't give you an engine at all, and you see the Missing
engine package error in the preceding section. Request or wait for
support for that platform instead of setting an environment variable.
