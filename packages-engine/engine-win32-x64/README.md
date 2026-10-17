# @blbaker/react-native-impeller-platform-engine-win32-x64

Prebuilt engine binary for `react-native-impeller-platform` on Windows x64.

Installed automatically as an optional dependency — do not depend on it directly.
Version is locked in step with `react-native-impeller-platform`; the resolver refuses a
mismatch because the engine C ABI is not stable across versions.

## Runtime requirements

- **Windows 10 version 1903 or later.** Hermes is built against the ICU that
  ships in System32 from that release (`icuuc.dll`, `icuin.dll`). Earlier
  Windows has no system ICU and the engine will not load.
- **A GPU with a D3D11 driver.** Rendering goes through ANGLE's D3D11 backend;
  `libEGL.dll` and `libGLESv2.dll` ship in this package.
- **No Visual C++ redistributable install is required** — the MSVC runtime DLLs
  are shipped app-local beside the executable.

Impeller SDK pin: `114eb184d66d7ca136d89eb8ec09f61aff265062`
ANGLE pin: `v43.3.0`
React Native (ReactCommon) pin: `0.86.2`
