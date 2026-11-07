# @blbaker/react-native-impeller-platform-engine-linux-arm64

Prebuilt engine binary for `react-native-impeller` on linux-arm64.

Installed automatically as an optional dependency — do not depend on it directly.
Version is locked in step with `react-native-impeller`; the resolver refuses a
mismatch because the engine C ABI is not stable across versions.

Window system: Wayland or X11, picked at run time (GLFW 3.4 with both backends;
`RNI_GLFW_PLATFORM=wayland|x11` forces one). GPU: libEGL.so.1 + libGLESv2.so.2 only.

Impeller SDK pin: `114eb184d66d7ca136d89eb8ec09f61aff265062`
React Native (ReactCommon) pin: `0.86.2`
