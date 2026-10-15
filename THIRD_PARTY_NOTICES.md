# Third-party notices

This project links against or vendors the following third-party software.
Nothing here replaces the original license text; see each project's own
repository for the authoritative license.

## Linked at build time

| Project | License | Role |
|---|---|---|
| [Flutter / Impeller](https://github.com/flutter/flutter) | BSD-3-Clause | The rendering engine `engine/` embeds. We link against a pinned Impeller SDK build (see `engine/IMPELLER_SHA`). |
| [React Native](https://github.com/facebook/react-native) | MIT | The JS framework and Fabric renderer this is an out-of-tree platform for. The engine vendors RN's C++ core (`engine/rn`, pinned via `engine/rn/package.json`). |
| [Hermes](https://github.com/facebook/hermes) | MIT | The JS engine, built from source and linked into the native host. |
| [GLFW](https://github.com/glfw/glfw) | zlib/libpng | Windowing and input on the desktop GL backends (fetched by `tools/glfw-fetch.sh`, not committed). |
| [ANGLE](https://github.com/google/angle) | BSD-3-Clause | Translates GLES calls to Metal (macOS) and Direct3D 11 (Windows). |
| [Boost](https://www.boost.org/) | Boost Software License 1.0 | Used by a small number of engine modules (see `engine/third_party`). |

## Fonts

Fixtures and example apps in this repo bundle open fonts for deterministic
rendering in CI (not shipped to consumers of the published packages):

| Font | License |
|---|---|
| Geist, Geist Mono | SIL Open Font License 1.1 |

## Build tooling

| Project | License | Role |
|---|---|---|
| [CMake](https://cmake.org/) | BSD-3-Clause | Build system for the C++ engine. |
| [Ninja](https://ninja-build.org/) | Apache-2.0 | Build backend used by CMake in CI. |
| [actionlint](https://github.com/rhysd/actionlint) | MIT | Lints the GitHub Actions workflows in CI. |

## None of the above is exhaustive

This file covers the dependencies with the largest footprint or the ones most
likely to raise a licensing question. `engine/third_party/` and
`engine/rn/package-lock.json` are the source of truth for exact versions and
transitive dependencies. If you spot something missing, please open an issue
or a pull request.
