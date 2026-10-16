# react-native-impeller

An out-of-tree React Native platform that renders through Flutter's Impeller
engine instead of Skia or the platform's native UI toolkit. React Native's
Fabric tree drives an embedded C++ Impeller renderer (native Metal on macOS,
OpenGL ES on Linux and Windows), so the same app can run on desktop targets
React Native does not support out of the box.

The renderer follows Flutter's own Impeller integration: a dedicated raster
thread fed by a depth-2 frame pipeline, vsync-paced frame scheduling, native
animations ticked off the JS thread, and the same backend choice per OS that
Flutter ships. The design, with file:line citations into Flutter's source, is in
[docs/eng/flutter-parity/](docs/eng/flutter-parity/README.md).

## Status

Pre-release and under active development. The API surface, package names, and
versions (currently `0.0.1` everywhere) are not stable yet. Expect breaking
changes between releases until a `1.0.0` is tagged. See
[docs/OPEN-SOURCE-READINESS.md](docs/OPEN-SOURCE-READINESS.md) for a full
audit of what still needs attention before this repo is announced publicly.

## Platforms

| Platform | Package | Backend | Status |
|---|---|---|---|
| macOS (arm64) | `@react-native-impeller/engine-darwin-arm64` | Native Metal (4x MSAA); ANGLE/GLES with `--backend gles` | Supported |
| Linux (x64) | `@react-native-impeller/engine-linux-x64` | OpenGL ES over EGL (Mesa) | Supported |
| Windows (x64) | `@react-native-impeller/engine-win32-x64` | OpenGL ES over ANGLE (Direct3D 11) | Supported |
| Android (arm64) | none yet | Vulkan, OpenGL ES fallback for known-bad drivers | Experimental: an embeddable view that draws Impeller display lists into a `SurfaceView`. No React Native runtime runs on it yet, so Android apps still use stock React Native. |
| iOS | none | n/a | Not supported yet. Flutter uses Metal there; an iOS host is future work. |

The backend per OS matches what Flutter ships: Metal on Apple platforms, Vulkan
with an OpenGL ES fallback on Android, and OpenGL ES on Linux and on Windows
(through ANGLE).

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

The prebuilt packages cover the three desktop platforms above. Building the engine
itself from a clean clone, running the gates, and the contributor workflow in
general are covered in [CONTRIBUTING.md](CONTRIBUTING.md).

## How this repo is organized

- `engine/` --- the C++ Impeller host: scene graph, Fabric mounting, native
  modules (clipboard, networking, storage, crypto, ...), platform surfaces
  (GLFW with Metal on macOS, EGL on Linux, ANGLE on Windows; the Android view in
  `engine/host/Android*` and `android/`).
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
