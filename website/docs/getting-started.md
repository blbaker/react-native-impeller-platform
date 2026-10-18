---
title: Getting started
---

# Getting started

## Requirements

- Node.js 20 or later.
- React Native 0.86.0 or later (a peer dependency).
- One of the supported platforms: Linux (x64), macOS (arm64), or Windows
  (x64). See [Platforms and requirements](./reference/platforms-and-requirements)
  for backend and build details.

## Install

```bash
npm install react-native react-native-impeller-platform
```

The engine binary is not inside `react-native-impeller-platform` itself. It
installs automatically as an optional dependency that matches your platform
and CPU architecture:

- `@blbaker/react-native-impeller-platform-engine-linux-x64`
- `@blbaker/react-native-impeller-platform-engine-darwin-arm64`
- `@blbaker/react-native-impeller-platform-engine-win32-x64`

npm installs the one that matches your host and skips the rest. If your
platform isn't in that list yet, the resolver says so directly instead of
failing somewhere obscure. See [Debugging](./guides/debugging) for the
exact message.

Check which engine binary resolved for your machine:

```bash
npx impeller-engine-path
```

That prints the resolved path, or an error naming the package it expected
to find.

## Scaffold a project

```bash
npx react-native init-impeller
```

This copies an `impeller/` folder into your app (scaffolded from your
`app.json` or `package.json`, not a hardcoded template) and wraps your
`metro.config.js` with `withImpeller` so Metro knows about the
`impeller` platform. Pass `--force` to overwrite files that already exist.

## Run it

```bash
npx react-native run-impeller
```

This bundles your app with Metro for `platform=impeller`, resolves the
engine binary for your machine, and launches it with the bundle path. Pass
`--release` to build a production bundle instead of a development one.

## Using a locally built engine

`IMPELLER_ENGINE_BINARY` points the resolver at a binary you built yourself,
and it takes priority over the installed engine package:

```bash
export IMPELLER_ENGINE_BINARY=/path/to/rn-impeller
```

This exists for engine development, not as a way to work around a missing
platform package. If you find yourself setting it in an app, something is
wrong with the install, not with your app.

## Where to go next

- [How it works](./guides/how-it-works) walks through the architecture:
  Fabric, the scene graph, the raster thread, and how the engine binary gets
  resolved.
- [Platforms and requirements](./reference/platforms-and-requirements) has
  the backend and OS requirements per platform.
- [Debugging](./guides/debugging) has the exact error text for every failure
  mode the resolver and build scripts produce.
