# Security policy

## Supported versions

This project is pre-1.0. Only the latest published version of each package
receives security fixes; there is no long-term support branch yet.

## Reporting a vulnerability

Please do not open a public GitHub issue for a security report. Instead, use
GitHub's private vulnerability reporting for this repository (the "Report a
vulnerability" button under the Security tab), or email the maintainer listed
in [CODEOWNERS](CODEOWNERS).

Include, if you can:

- the affected package and version
- a minimal reproduction (a fixture app, a bundle, or a code snippet)
- the platform and engine build involved (darwin-arm64, linux-x64, or
  win32-x64, and the engine commit SHA if known)
- the impact you believe it has

You should get an acknowledgment within a few days. This is a small,
pre-release project maintained outside of working hours, so please be patient
on turnaround.

## Scope

In scope: the `react-native-impeller-platform` package, the prebuilt engine
packages, and the engine source under `engine/`. Vulnerabilities in upstream
dependencies (React Native, Impeller/Flutter, GLFW, ANGLE, Hermes) should be
reported to those projects directly; feel free to also flag them here if this
repo ships an affected version so we can track an upgrade.
