// ENG-01d probe app. Mirrors a consumer app's metro.config.js:
// withNativewind(withImpeller(getDefaultConfig())) on Expo 57 + NativeWind 5.
// tools/build-textinput-inline-os-bundles.sh drives the arms with env vars:
//   RNI_NO_IMPELLER=1      no withImpeller at all (the bundler still has to
//                          accept the platform name, so only that is added)
//   RNI_NO_TRANSFORMER=1   withImpeller, but its babel-transformer wrapper is
//                          taken back out: the resolver-only shim that shipped
//                          before ENG-01d (the control arm, must not mount)
//   RNI_NO_NW=1            skip withNativewind (NativeWind needs withImpeller's
//                          reanimated stub, so the no-withImpeller arm drops it)
const path = require('path');
const { getDefaultConfig } = require('expo/metro-config');
const { withImpeller } = require('react-native-impeller-platform/src/metro-shims');
const { withNativewind } = require('nativewind/metro');

const config = getDefaultConfig(__dirname);
config.resolver.nodeModulesPaths = [path.join(__dirname, 'node_modules')];

let inner;
if (process.env.RNI_NO_IMPELLER === '1') {
  config.resolver.platforms = [...(config.resolver.platforms || []), 'impeller'];
  inner = config;
} else {
  const upstreamBabel = config.transformer.babelTransformerPath;
  const upstreamCacheVersion = config.cacheVersion;
  inner = withImpeller(config);
  if (process.env.RNI_NO_TRANSFORMER === '1') {
    inner = {
      ...inner,
      cacheVersion: upstreamCacheVersion,
      transformer: { ...inner.transformer, babelTransformerPath: upstreamBabel },
    };
  }
}

module.exports =
  process.env.RNI_NO_NW === '1'
    ? inner
    : withNativewind(inner, { inlineRem: 16, disableTypeScriptGeneration: true });
