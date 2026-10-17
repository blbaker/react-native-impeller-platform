const path = require('path');
const {getDefaultConfig} = require('expo/metro-config');
const {withImpeller} = require('react-native-impeller-platform/src/metro-shims');
const base = getDefaultConfig(__dirname);
base.watchFolders = [...(base.watchFolders || []), path.dirname(require.resolve('react-native-impeller-platform/package.json'))];
base.resolver.nodeModulesPaths = [path.join(__dirname, 'node_modules')];
module.exports = withImpeller(base);
