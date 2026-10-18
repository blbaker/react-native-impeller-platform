---
title: Debugging
---

# Debugging

The resolver and build scripts are written to name the exact problem rather
than fail somewhere obscure. These are the real messages you'll see, and
what each one means.

## "GLFW not found" during the CMake configure step

GLFW is fetched by a script, not committed to the repository. A clean clone
doesn't build with `tools/engine-build.sh` alone. Run this first:

```bash
bash tools/glfw-fetch.sh
```

Then build the engine as usual. See
[Building the engine from source](./building-the-engine-from-source).

## "react-native-impeller-platform does not support `<platform>-<arch>` yet."

Your platform and CPU combination isn't in the resolver's supported set
(currently `linux-x64`, `win32-x64`, and `darwin-arm64`). The error message
includes a link to track or request support for it. Setting
`IMPELLER_ENGINE_BINARY` won't help here; there's no published engine for
your triple to point at.

## "Missing engine package `<name>`."

The resolver looked for the per-platform engine package and didn't find it.
The error lists every path it checked. This usually means the optional
dependency didn't install, most often because `npm install` ran with
`--no-optional`, or because an engine package was published after you last
ran `npm install`. Install it explicitly:

```bash
npm install @blbaker/react-native-impeller-platform-engine-<platform>-<arch>@<version>
```

If you're working from a linked source checkout (`npm link` or `file:`)
instead of a normal install, see the next section.

## "Engine version mismatch"

```
Engine version mismatch: @blbaker/react-native-impeller-platform-engine-linux-x64@0.0.2 is installed
but react-native-impeller-platform@0.1.0 requires exactly 0.1.0.
```

The host package and every engine package ship at the same version in
lockstep, because the engine exposes a C ABI that isn't stable across
versions. A mismatch isn't a warning, it's a hard failure, because a mixed
pair crashes at runtime in ways that look like renderer bugs. Install the
matching version named in the error.

## "Engine package is installed but its binary is missing"

If you're consuming a normal install, the package is corrupt; reinstall it.
If you're working from a linked source checkout, this is expected until you
build the engine yourself:

```bash
bash tools/engine-build.sh <platform> <arch>
```

`packages-engine/*/bin` is intentionally left out of git, so a checkout with
no build has a `package.json` but no binary.

## "IMPELLER_ENGINE_BINARY is set to `<path>` but no file exists there."

The environment variable is pointed at a path that doesn't exist. Unset it
to fall back to the installed engine package, or point it at a binary you
actually built.

## A platform not in the install list

`npm` silently skips a missing optional dependency and exits `0`. If your
platform isn't in the table on the
[Platforms and requirements](../reference/platforms-and-requirements) page,
installing won't give you an engine at all, and you'll hit "Missing engine
package" above. The fix there isn't to set an environment variable; it's to
wait for or request support for that platform.
