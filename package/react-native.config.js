// CLI + platform registration for the `impeller` out-of-tree platform.
//
// PLAN D1: `npmPackageName` is deliberately NOT set. Setting it declares this
// package a react-native FORK and makes the CLI/Metro redirect InitializeCore into
// it -- the exact failure documented in the skia-platform packaging notes. This is
// an OVERLAY platform: it sits beside stock react-native.
const cli = require('./src/cli');

module.exports = {
  commands: cli.commands,
  platforms: {
    impeller: {
      linkConfig: () => ({
        isInstalled: () => false,
        register: () => {},
        unregister: () => {},
        copyAssets: () => {},
        unlinkAssets: () => {},
      }),
      projectConfig: (root, userConfig) => (userConfig ? {...userConfig, root} : null),
      dependencyConfig: () => null,
    },
  },
};
