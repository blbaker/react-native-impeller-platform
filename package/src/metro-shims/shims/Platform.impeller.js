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
  // Populated by the engine host via the PlatformConstants TurboModule (P4).
  get Version() {
    return (this.constants && this.constants.osVersion) || 0;
  },
  get constants() {
    return this.__constants || {};
  },
  get isTesting() {
    return process.env.NODE_ENV === 'test';
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
