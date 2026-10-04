// Same transformer HostApp uses (apps/hostapp/css-transformer.js): RN's worker for JS,
// Tailwind then react-native-css's compiler for .css. Not a runtime shim.
const path = require('path');
const worker = require(require.resolve('metro-transform-worker', {paths: [path.dirname(require.resolve('metro/package.json', {paths: [require.resolve('@react-native/metro-config')]}))]}));
const postcss = require('postcss');
const tailwind = require('@tailwindcss/postcss');
const {compile} = require('react-native-css/compiler');
async function transform(config, projectRoot, filePath, data, options) {
  const isCss = options.type !== 'asset' && /\.css$/.test(filePath);
  if (!isCss) return worker.transform(config, projectRoot, filePath, data, options);
  const out = await postcss([tailwind({base: projectRoot})]).process(data.toString(), {from: filePath});
  const js = compile(out.css, {...(config.reactNativeCSS || {}), filename: filePath, projectRoot}).stylesheet();
  const code = `import { StyleCollection } from "react-native-css/native-internal";\nStyleCollection.inject(${JSON.stringify(js)});export {};`;
  return worker.transform(config, projectRoot, `${filePath}.js`, Buffer.from(code), options);
}
module.exports = {transform, getCacheKey: worker.getCacheKey};
