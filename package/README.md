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
then an error telling you to install a package that does not exist.

If your platform is not listed, it is not supported yet. `resolveEngine` says so
directly rather than failing obscurely at runtime.

## Not published yet — what that means for you

Until the first release lands on npm there is no consumer story, and this
README will not pretend otherwise. **Do not build the engine to use this
package.** Compiling Hermes from source, installing Xcode and cmake, packing
tarballs by hand, or running a local registry are all things a *contributor to
this repo* does. A consumer runs `npm install` and nothing else.

If you want to use `@react-native-impeller/core` in an app today, the honest
answer is: wait for the release. The install above is the entire intended
experience, and it is one command deliberately — the engine arrives as an
optional dependency selected by your platform, with no build step, no native
toolchain, and no environment variables.

`IMPELLER_ENGINE_BINARY` exists for engine development, not for consumption. If
you find yourself setting it in an app, something is wrong with the package and
that is a bug worth reporting.

---

# Contributing to this repo

Everything below is for working ON react-native-impeller. None of it is
required — or appropriate — for using the published package.

## Installing it locally, before the first npm release

You can consume the package on this machine exactly the way a published install
works — `npm install @react-native-impeller/core`, no flags, no env vars, no
build step in the consuming app — with a throwaway local registry:

```bash
npx verdaccio --listen 127.0.0.1:4873
cd package && npm publish --registry http://127.0.0.1:4873
cd ../packages-engine/engine-$(node -p 'process.platform+"-"+process.arch') \
  && npm publish --registry http://127.0.0.1:4873

# in a scratch app — exactly what a published install will look like
npm install @react-native-impeller/core --registry http://127.0.0.1:4873
```

Point only that one app's `.npmrc` at the local registry (a **scoped** line),
never a global `registry=`:

```
@react-native-impeller:registry=http://127.0.0.1:4873
```

⛔ Scoped, never global. Everything else — React, React Native, the whole rest
of the tree — keeps resolving from npmjs. A global redirect routes an app's
entire dependency graph through a throwaway server, which is a supply-chain
change nobody asked for.

Bump the version in every `package.json` before re-publishing; a registry
refuses to overwrite an existing version, the same as npmjs.

(Baker's own dev loop also keeps a *persistent* local registry running via a
systemd/launchd unit and a wrapper script, so he doesn't have to repeat the
steps above on every rebuild. That wrapper and its unit files are specific to
his machines and aren't included in this public copy; the commands above are
the portable, manual equivalent.)

## Building the engine

```bash
bash tools/engine-build.sh <platform> <arch>   # e.g. darwin arm64
```

Needs a C++ toolchain, `cmake`, `ninja` and Node 18+ (on macOS: full Xcode, not
just Command Line Tools). The first run compiles Hermes from source at the exact
tag React Native pins — budget ~40 minutes; later builds reuse it.

## Testing the consumer experience

```bash
bash tools/pack-and-consume.sh   # installs packed tarballs into a pristine app
```

Installing a tarball by path hand-places the package and **cannot** exercise
what a real user hits: npm reading `optionalDependencies` and selecting the
one engine whose `os`/`cpu` match. npm skips an optional dependency it cannot
use *and exits 0*, so every failure in that path is silent — `pack-and-consume.sh`
still only proves the by-path install. For the by-name, real-`npm publish`
version of this check (a by-name registry gate isn't part of this repo), use the manual verdaccio recipe above and check both that the
host's engine arrived and that no foreign-platform engine did.

## Using a locally built engine (engine development only)

`IMPELLER_ENGINE_BINARY` points the resolver at a binary you built yourself:

```bash
export IMPELLER_ENGINE_BINARY=/path/to/rn-impeller
```

It takes priority over the installed engine package and skips the version
lockstep check.

> **This is not a consumer workaround.** It exists so engine developers can test
> a build without packing it. If a platform has no published engine package, the
> answer is to publish one — not to tell users to set an environment variable.
> A package that requires an env var to function has not shipped.

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
