'use strict';
// Platform variant for react-native/Libraries/Components/ScrollView only.
//
// ScrollView.js decides `pagingEnabled` with Platform.select({ios, android})
// and no default, and processDecelerationRate.js turns 'normal'/'fast' into a
// number the same way. On impeller both answered undefined, so a
// pagingEnabled pager never told native it pages and could not snap to a
// page under a touch drag.
//
// Only select() changes: with no impeller/native arm it falls back to the ios
// arm, the desktop-shaped one. OS stays 'impeller', so the folder's
// `Platform.OS === 'ios'` branches (the RefreshControl wrapper, zoomToRect)
// behave exactly as before. The whole folder gets this module because Metro
// caches Platform's resolution per origin folder (index.js, ENG-01c).
const Platform = require('./Platform.impeller.js');

const PlatformSelectIos = Object.create(Platform);
PlatformSelectIos.select = function select(spec) {
  if ('impeller' in spec || 'native' in spec) return Platform.select(spec);
  if ('ios' in spec) return spec.ios;
  return spec.default;
};

module.exports = PlatformSelectIos;
module.exports.default = PlatformSelectIos;
