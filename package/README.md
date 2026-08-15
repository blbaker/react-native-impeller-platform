# react-native-impeller

An out-of-tree React Native platform whose renderer is
[Impeller](https://github.com/flutter/engine/tree/main/impeller), Flutter's
graphics engine. React components mount through Fabric into a scene graph that
Impeller paints — no DOM, no native view hierarchy, no per-platform UI toolkit.

**Status: pre-release, and honest about it.** The rendering, the JS↔native
module seam and the packaging are gated by pixel tests on every commit, but the
API surface is small and the published platform list is short. See "Supported
platforms" before installing.

## Install

```bash
npm install react-native-impeller
```

The engine binary is not in this package. It installs automatically as an
optional dependency matching your platform and architecture.

## Supported platforms

| Platform | Engine package | Status |
|---|---|---|
| linux-x64 | `@react-native-impeller/engine-linux-x64` | published |
| win32-x64 | `@react-native-impeller/engine-win32-x64` | published |
| darwin-arm64 | — | in progress |
| darwin-x64, linux-arm64 | — | not started |

**A platform is listed as published only once its engine package actually
exists.** npm silently skips a missing optional dependency and exits 0, so
declaring a platform we cannot ship would give you a clean install with no
engine — and then an error telling you to install a package that does not
exist. If your platform is not listed, `resolveEngine` says so directly and
points at `IMPELLER_ENGINE_BINARY`.

## Using a locally built engine

Any platform can be driven by a binary you built yourself:

```bash
export IMPELLER_ENGINE_BINARY=/path/to/rn-impeller
```

This takes priority over the installed engine package and skips the version
lockstep check — it is the supported path for engine development and for
platforms with no published package yet.

## Versioning

The host package and every engine package are released in **lockstep at exactly
the same version**, and the resolver refuses a mismatched pair rather than
letting it fail at runtime:

```
Engine version mismatch: @react-native-impeller/engine-linux-x64@0.0.2 is installed
but react-native-impeller@0.0.1 requires exactly 0.0.1.
```

The engine exposes a C ABI that is not stable across versions, so this is a hard
requirement, not a convention. Never pin an engine package with `^` or `~`;
`tools/ci-release-meta.sh` fails the build if a range appears.

## Requirements

- Node.js >= 20
- React Native >= 0.86 (peer dependency)

## License

MIT
