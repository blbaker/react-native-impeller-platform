---
title: Get started
---

# Get started

This page shows you how to add react-native-impeller-platform to a React
Native app and run the app on your desktop.

## Before you begin

Make sure that your machine meets the following requirements:

- Node.js 20 or later is installed.
- Your app uses React Native 0.86.0 or later.
- Your computer runs Linux on x64, macOS on Apple silicon (arm64), or
  Windows on x64.

For more information about graphics backends and build details, see
[Platforms and requirements](./reference/platforms-and-requirements).

## Install the package

To install React Native and the platform package, run the following command
in your app's root directory:

```bash
npm install react-native react-native-impeller-platform
```

The engine binary isn't part of the `react-native-impeller-platform`
package. npm installs it as an optional dependency, and it installs only the
engine package that matches your operating system and CPU:

- `@blbaker/react-native-impeller-platform-engine-linux-x64`
- `@blbaker/react-native-impeller-platform-engine-darwin-arm64`
- `@blbaker/react-native-impeller-platform-engine-win32-x64`

If no engine package exists for your platform, the resolver reports the
platform by name. For the exact message, see [Debugging](./guides/debugging).

## Verify the engine

To confirm that an engine binary is available for your machine, run the
following command:

```bash
npx impeller-engine-path
```

The command prints the path to the engine binary. If the engine package is
missing, the command prints the name of the package that it expected to find.

## Add the platform to your app

To add the Impeller platform files to your app, run the following command:

```bash
npx react-native init-impeller
```

The command does the following:

- Creates an `impeller/` directory in your app. The command reads the app
  name from your `app.json` or `package.json` file.
- Wraps your `metro.config.js` file with `withImpeller` so that Metro can
  build for the `impeller` platform.

To overwrite files that already exist, add the `--force` flag.

## Run your app

To bundle your app and open it in the engine, run the following command:

```bash
npx react-native run-impeller
```

The command bundles your app with Metro for the `impeller` platform, finds
the engine binary for your machine, and starts the engine with the bundle.

To build a production bundle instead of a development bundle, add the
`--release` flag.

## Optional: Use a locally built engine

If you build the engine from source, you can point the resolver at your
build. The `IMPELLER_ENGINE_BINARY` environment variable takes priority over
the installed engine package:

```bash
export IMPELLER_ENGINE_BINARY=ENGINE_BINARY_PATH
```

Replace `ENGINE_BINARY_PATH` with the absolute path to your `rn-impeller`
binary.

**Note:** This variable is for engine development. If an app needs it to
run, the engine package didn't install correctly. For more information, see
[Debugging](./guides/debugging).

## What's next

- To learn how the engine renders your app, see
  [How it works](./guides/how-it-works).
- To check the requirements for each operating system, see
  [Platforms and requirements](./reference/platforms-and-requirements).
- To fix an install or launch error, see [Debugging](./guides/debugging).
