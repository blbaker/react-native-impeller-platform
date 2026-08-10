'use strict';
// Platform shim for Platform.OS === 'impeller'.
//
// The literal below is the PACKAGING MARKER. tools/pack-and-consume.sh greps the
// produced Metro bundle for it: if the marker is absent, the shim never made it
// into the tarball or metro never resolved it, and the consumer path is broken --
// regardless of whether the build "succeeded".
const RN_IMPELLER_SHIM_MARKER = '__RN_IMPELLER_SHIM_V1__';

const Platform = {
  __constants: null,
  OS: 'impeller',
  get Version() {
    return this.constants.osVersion || 0;
  },
  // P4: actually READ the PlatformConstants TurboModule. Until now this
  // returned `{}`, so `Platform.constants.reactNativeVersion` was undefined and
  // `Platform.Version` was 0 — while the native module sat there answering
  // correctly and nothing indicated the two were not connected.
  //
  // TurboModuleRegistry.get (not getEnforcing): if the module is somehow
  // absent, a Platform that reports empty constants is far better than a
  // bundle that dies at import over a version string.
  get constants() {
    if (this.__constants == null) {
      const TurboModuleRegistry = require('react-native/Libraries/TurboModule/TurboModuleRegistry');
      const NativePlatformConstants = TurboModuleRegistry.get('PlatformConstants');
      this.__constants = NativePlatformConstants
        ? NativePlatformConstants.getConstants()
        : {};
    }
    return this.__constants;
  },
  get isTesting() {
    return this.constants.isTesting === true;
  },
  get isTV() {
    return false;
  },
  get isVision() {
    return false;
  },
  select(spec) {
    if ('impeller' in spec) return spec.impeller;
    if ('native' in spec) return spec.native;
    return spec.default;
  },
  __marker: RN_IMPELLER_SHIM_MARKER,
};

module.exports = Platform;
module.exports.default = Platform;
module.exports.RN_IMPELLER_SHIM_MARKER = RN_IMPELLER_SHIM_MARKER;
