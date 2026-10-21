---
title: CLI reference
---

# CLI reference

These commands come from `react-native-impeller-platform` itself: two
React Native Community CLI commands (`init-impeller`, `run-impeller`) and
one standalone binary (`impeller-engine-path`).

## react-native init-impeller

To scaffold the Impeller platform files into your app, run the following
command:

```bash
npx react-native init-impeller
```

The command scaffolds an `impeller/` folder into the current React Native
app and wraps `metro.config.js` with `withImpeller` so Metro knows about
the `impeller` platform. The scaffold is generated from the app's
`app.json` or `package.json` file, not copied from a fixed template.

The following table lists the options for `init-impeller`:

| Option | Type | Default | Description |
|---|---|---|---|
| `--force` | boolean | `false` | Overwrite scaffolded files that already exist. |

## react-native run-impeller

To bundle your app and launch it in the engine, run the following
command:

```bash
npx react-native run-impeller
```

The command bundles the app with Metro for `platform=impeller`, resolves
the engine binary for the current machine, and launches it with the
bundle's absolute path.

The following table lists the options for `run-impeller`:

| Option | Type | Default | Description |
|---|---|---|---|
| `--release` | boolean | `false` | Build a production Metro bundle instead of a development one. |

## impeller-engine-path

To check which engine binary your install resolved, run the following
command:

```bash
npx impeller-engine-path
```

The command prints the resolved engine binary's absolute path to stdout,
or a message naming the expected package to stderr, and exits `1`. It
takes no options. Use it to check what an install resolved, and during
continuous integration.

## Environment variables

The following table lists the environment variables that affect engine
resolution:

| Variable | Type | Default | Description |
|---|---|---|---|
| `IMPELLER_ENGINE_BINARY` | path | unset | Points the resolver at a binary you built yourself. Takes priority over the installed engine package. For engine development; see [Build the engine from source](../guides/building-the-engine-from-source). |

For more information about what the resolver prints when resolution fails
at each of these steps, see [Debugging](../guides/debugging).
