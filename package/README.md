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

> **Not published yet.** These packages are configured to publish **publicly**,
> but nothing has been released to npm — publishing stays deliberately gated
> while the API settles. Until the first release, install from a git checkout or
> a packed tarball. The command below will work once a version ships.

```bash
npm install @react-native-impeller/core
```

The engine binary is not in this package. It installs automatically as an
optional dependency matching your platform and architecture.

## Supported platforms

| Platform | Engine package | Status |
|---|---|---|
| linux-x64 | `@react-native-impeller/engine-linux-x64` | builds + renders |
| win32-x64 | `@react-native-impeller/engine-win32-x64` | builds + renders |
| darwin-arm64 | `@react-native-impeller/engine-darwin-arm64` | builds + renders |
| darwin-x64, linux-arm64 | — | not started |

Nothing is on npm yet — see Install. "builds + renders" means the engine
package exists, installs into an app outside the repo, and puts correct pixels
on screen there (P1 consumer + P2 mount + P3 conformance + P4 module seam).

**A platform is listed only once its engine package actually exists.** npm
silently skips a missing optional dependency and exits 0, so declaring a
platform we cannot ship would give you a clean install with no engine — and
then an error telling you to install a package that does not exist. If your
platform is not listed, `resolveEngine` says so directly and points at
`IMPELLER_ENGINE_BINARY`.

## Using it on macOS today (before the first npm release)

darwin-arm64 (Apple Silicon) is fully supported by the code; it just is not
published yet. Two ways to consume it right now, both exercised by
`tools/pack-and-consume.sh` on a real Mac:

**1. Install from packed tarballs** — the closest thing to the published
experience, and the one the consumer gate actually runs:

```bash
# in the react-native-impeller checkout, on the Mac
bash tools/engine-build.sh darwin arm64          # builds + stages the engine
(cd packages-engine/engine-darwin-arm64 && npm pack --pack-destination /tmp)
(cd package && npm pack --pack-destination /tmp)

# in YOUR app
npm install /tmp/react-native-impeller-engine-darwin-arm64-0.0.1.tgz \
            /tmp/react-native-impeller-core-0.0.1.tgz
npx react-native init-impeller                   # scaffolds impeller/, wraps metro.config.js
npx react-native run-impeller                    # bundles for --platform impeller and runs
```

**2. Point at a locally built engine** — no packing, best while iterating on the
engine itself:

```bash
export IMPELLER_ENGINE_BINARY=/path/to/react-native-impeller/packages-engine/engine-darwin-arm64/bin/rn-impeller
```

### Requirements on the Mac

Xcode (full, not just Command Line Tools), plus `cmake` and `ninja`
(`brew install cmake ninja`) and Node 18+. The first build compiles Hermes from
source at the exact tag React Native pins — budget ~40 minutes on 8 cores; every
build after that reuses it.

### ⚠️ Headless only over SSH

The engine renders offscreen through ANGLE→Metal and writes a `.ppm`, which is
all the gates need. Cocoa cannot open a window from an SSH session
(`launchctl managername` is `Background`), so a visible window requires a
Terminal in the GUI session.

## Local development against a real registry

The install commands above use tarball paths, which is fine for a smoke test and
**does not exercise the mechanism a real user depends on**: npm reading
`optionalDependencies` off `@react-native-impeller/core` and selecting the one
engine whose `os`/`cpu` match the host. Installing a tarball by path hand-places
the package and bypasses that selection entirely.

To develop against the real thing, run a private registry locally:

```bash
bash tools/ci-registry.sh          # publishes + installs by name, then cleans up
```

That script starts verdaccio on `127.0.0.1:4873`, publishes every built package
with the real `npm publish`, installs `@react-native-impeller/core` **by name**
into a pristine app, and asserts npm picked the right engine (and only that
one). It is gate 13 in `tools/ci-all.sh`.

To keep a registry running and point your own app at it:

```bash
npx verdaccio --listen 4873                      # terminal 1
cd package && npm publish --registry http://127.0.0.1:4873
cd ../packages-engine/engine-$(node -p 'process.platform+"-"+process.arch') \
  && npm publish --registry http://127.0.0.1:4873

# in YOUR app — exactly what a published install will look like
npm install @react-native-impeller/core --registry http://127.0.0.1:4873
```

Bump the version in every `package.json` before re-publishing; a registry
refuses to overwrite an existing version, the same as npmjs.

> **Safety:** `tools/ci-registry.sh` refuses to run unless the registry URL
> resolves to loopback, and writes a throwaway `.npmrc` in its work directory
> rather than touching `~/.npmrc`, so it cannot reach npmjs or read your
> credentials. Publishing to npm proper stays gated behind `RNI_PUBLISH_ENABLED`
> in the release workflow.

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
