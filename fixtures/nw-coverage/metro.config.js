// ENG-19: the WHOLE app-side Metro config. No resolveRequest of its own, no
// metro-shims folder: withImpeller (the package) + withNativewind only.
const path = require('path');
const {withImpeller} = require('@react-native-impeller/core/src/metro-shims');
const {getDefaultConfig} = require('@react-native/metro-config');
const {withNativewind} = require('nativewind/metro');

const nw = withNativewind(withImpeller(getDefaultConfig(__dirname)), {
  inlineRem: 16,
  disableTypeScriptGeneration: true,
});
// react-native-css's own transformer delegates to Expo's worker; a bare RN CLI
// app needs RN's worker for JS and Tailwind + react-native-css for .css (same
// as HostApp's css-transformer.js). This is a build-tool choice, not a shim.
nw.transformerPath = path.join(__dirname, 'css-transformer.js');
module.exports = nw;
