'use strict';
// SC-18. RN sends style.fontFamily to Fabric untouched, and the C++ prop parser
// only accepts a string, so NativeWind's `font-mono` (an array) failed with
// "Error while converting prop 'fontFamily'". Re-export RN's own table with a
// fontFamily processor that joins arrays into one CSS stack; the engine picks
// the first family in the stack that resolves (engine/text/FontFamily.cpp).
// Required by explicit path from this file, which index.js does not redirect.
const real = require('react-native/Libraries/Components/View/ReactNativeStyleAttributes');
const attributes = real.default || real;

function processFontFamily(value) {
  if (Array.isArray(value)) {
    return value.filter((v) => typeof v === 'string' && v.length > 0).join(', ');
  }
  return value;
}

attributes.fontFamily = {process: processFontFamily};

module.exports = real;
