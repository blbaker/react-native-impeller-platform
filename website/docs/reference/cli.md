---
title: CLI reference
---

# CLI reference

These commands come from `react-native-impeller-platform` itself: two
React Native Community CLI commands (`init-impeller`, `run-impeller`) and
one standalone binary (`impeller-engine-path`).

## `react-native init-impeller`

```bash
npx react-native init-impeller
```

Scaffolds an `impeller/` folder into the current React Native app and
wraps `metro.config.js` with `withImpeller` so Metro knows about the
`impeller` platform. The scaffold is generated from the app's own
`app.json` or `package.json`, not copied from a fixed template.

| Option | Type | Default | Description |
|---|---|---|---|
| `--force` | boolean | `false` | Overwrite scaffolded files that already exist. |

## `react-native run-impeller`

```bash
npx react-native run-impeller
```

Bundles the app with Metro for `platform=impeller`, resolves the engine
binary for the current machine, and launches it with the bundle's absolute
path.

| Option | Type | Default | Description |
|---|---|---|---|
| `--release` | boolean | `false` | Build a production Metro bundle instead of a development one. |

## `impeller-engine-path`

```bash
npx impeller-engine-path
```

Prints the resolved engine binary's absolute path to stdout, or a message
naming the expected package to stderr and exits `1`. Takes no options.
Useful for checking what an install actually resolved, and in CI.

## Environment variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `IMPELLER_ENGINE_BINARY` | path | unset | Points the resolver at a binary you built yourself. Takes priority over the installed engine package. For engine development; see [Building the engine from source](../guides/building-the-engine-from-source). |

See [Debugging](../guides/debugging) for what the resolver prints when
resolution fails at each of these steps.
