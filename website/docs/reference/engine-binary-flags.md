---
title: Engine binary flags
---

# Engine binary flags

The `rn-impeller` binary is the C++ engine host that `run-impeller`
launches for you. The following sections list its user-facing flags. Run
`rn-impeller --help` to see the full list. The full usage text also lists
flags for the engine's own test harness (synthetic input injection,
self-tests, draw-op dumps). Those flags aren't listed here because
they're not meant for an app developer to pass.

## Required

To launch the engine directly, pass the following required flags:

```bash
rn-impeller --bundle BUNDLE_PATH --app-name APP_NAME
```

Replace `BUNDLE_PATH` with the absolute path to the Metro bundle to load,
and `APP_NAME` with the app's display name. The following table describes
these flags:

| Flag | Type | Default | Description |
|---|---|---|---|
| `--bundle` | absolute path | none, required | The Metro bundle to load. `run-impeller` always passes this as an absolute path; the engine has no working-directory fallback. |
| `--app-name` | string | none, required | The app's display name. |

## Window and display

The following table lists the flags that control the engine's window and
display:

| Flag | Type | Default | Description |
|---|---|---|---|
| `--headless` | flag | off (windowed) | Render without opening a window. |
| `--window` | flag | off | Open a window explicitly (used together with the test-harness flags, which otherwise imply headless). |
| `--width` / `--height` | integer (N) | engine default | Framebuffer size in pixels. |
| `--scale` | number (N) | `1` headless; the display's real framebuffer/window ratio windowed | Device pixels per point. Windowed, this overrides the display's natural ratio, so a probe that asserts pointer coordinates against layout points should only pass it deliberately. |
| `--title` | string | `"React Native (Impeller)"` | Window title; also the macOS Window menu entry. |
| `--color-scheme` | `light` \| `dark` | engine default | Forces the app's color scheme. |
| `--initial-url` | URL | unset | URL the app's deep-link handling receives at launch. |
| `--screenshot` | path (`.ppm`) | unset | Write a screenshot to this path. |

## Rendering backend and quality

The following table lists the flags that control the rendering backend
and quality:

| Flag | Type | Default | Description |
|---|---|---|---|
| `--backend` | `gles` \| `metal` \| `vulkan` | `metal` on darwin windowed, `gles` elsewhere | GPU backend to render with. |
| `--supersample-rnsvg` | integer (N) | `4` on darwin and Windows, `0` (off) elsewhere | Offscreen supersample factor for stroked SVG icon antialiasing on backends with no surface-level MSAA. For more information, see [Styling](../guides/styling#anti-aliasing-depends-on-the-backend). |
| `--sdf-aa` | `on` \| `off` | `off` | Analytic SDF antialiasing for circles, ovals, rects, and rounded rects (Impeller's `Flags::use_sdfs`). |
| `--prewarm` | `on` \| `off` | `on` | Run a pipeline pre-warm pass before the first frame. |

## Resource budgets

The following table lists the flag that controls the image cache budget:

| Flag | Type | Default | Description |
|---|---|---|---|
| `--image-cache-mb` | integer (N) | `100` | Decoded-image LRU cache budget, in MB. Also settable with the `RNI_IMAGE_CACHE_MB` environment variable. |

The following table lists the related environment variables:

| Environment variable | Type | Default | Description |
|---|---|---|---|
| `RNI_IMAGE_CACHE_MB` | integer | `100` | Same as `--image-cache-mb`. |
| `RNI_IMAGE_CACHE_FLOOR_MB` | integer | `0` | Minimum cache size kept during a low-memory purge. |
| `RNI_FONT_DIRS` | path list | unset | Extra font directories for the Linux font resolver, same effect as `--font-dir`. For more information, see [Fonts and text](../guides/fonts-and-text#add-your-own-fonts-on-linux). |

## Profiling

The following table lists the flags that write profiling data:

| Flag | Type | Default | Description |
|---|---|---|---|
| `--frame-timings-out` | path (`.json`) | unset | Write one timing record per presented frame. |
| `--trace-out` | path (`.json`) | unset | Write a Chrome/Perfetto trace of spans and counters. |

## Self-test and diagnostic modes

To print the TurboModule seam as a machine-readable manifest without
loading a bundle, run the following command:

```bash
rn-impeller --list-modules
```

`--test-openurl`, `--test-urlparse`, and `--test-http` run the engine's own
networking and URL-handling self-tests the same way. None of the four
take a `--bundle` flag.
