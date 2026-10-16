# react-native-impeller

An out-of-tree React Native platform that renders through Flutter's Impeller
engine instead of Skia or the platform's native UI toolkit. React Native's
Fabric tree drives an embedded C++ Impeller renderer over OpenGL/ANGLE, so the
same app can run on desktop targets React Native does not support out of the
box.

## Status

Pre-release and under active development. The API surface, package names, and
versions (currently `0.0.1` everywhere) are not stable yet. Expect breaking
changes between releases until a `1.0.0` is tagged. See
[docs/OPEN-SOURCE-READINESS.md](docs/OPEN-SOURCE-READINESS.md) for a full
audit of what still needs attention before this repo is announced publicly.

## Platforms

| Platform | Package | Backend |
|---|---|---|
| macOS (arm64) | `@react-native-impeller/engine-darwin-arm64` | ANGLE over Metal |
| Linux (x64) | `@react-native-impeller/engine-linux-x64` | EGL/GLES (Mesa) |
| Windows (x64) | `@react-native-impeller/engine-win32-x64` | ANGLE over Direct3D 11 |

Each platform package ships a prebuilt engine binary and installs
automatically as an `optionalDependency` of `@react-native-impeller/core` ---
npm picks the one that matches the host and skips the rest.

## Quick start

```bash
npm install react-native @react-native-impeller/core
npx impeller-engine-path   # prints the resolved engine binary for this host
```

`@react-native-impeller/core` wires Fabric's view registry and component
configs to the Impeller renderer. See
[package/README.md](package/README.md) for the consumer-facing API.

## Building from source

The prebuilt packages cover the three platforms above. Building the engine
itself from a clean clone, running the gates, and the contributor workflow in
general are covered in [CONTRIBUTING.md](CONTRIBUTING.md).

## How this repo is organized

- `engine/` --- the C++ Impeller host: scene graph, Fabric mounting, native
  modules (clipboard, networking, storage, crypto, ...), platform surfaces
  (GLFW/EGL on Linux, ANGLE on macOS and Windows).
- `package/` --- `@react-native-impeller/core`, the JS package consumers
  install. Resolves the per-platform engine binary and wires Metro.
- `packages-engine/engine-<platform>-<arch>/` --- the prebuilt engine
  binaries, one package per platform/architecture pair, pinned in lockstep
  with `package/`.
- `tools/` --- build scripts and CI gates (`ci-*.sh`), each with a matching
  `mutation-verify-*.sh` that proves the gate can actually fail.
- `fixtures/` --- small React Native apps the gates render and compare
  pixel-by-pixel against an oracle.
- `docs/` --- engineering notes, design docs, and the engineering standards
  this repo is held to.

## License

MIT. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the licenses of what is
vendored or linked.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md),
and [SECURITY.md](SECURITY.md) for how to report a vulnerability.
