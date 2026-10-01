'use strict';
// parity item 20/12 (moved from HostApp's app-level metro-shims). PLACEHOLDER
// Image for the `impeller` platform, until the real Image component +
// ImageLoader land (parity item 17).
//
// WHY: Libraries/Image/Image.js is a self re-export (`import Image from
// './Image'`), so on impeller -- no .impeller.js sibling -- it resolves to
// ITSELF and its default export is undefined. Any <Image> then throws
// "Element type is invalid ... got: undefined". In a __DEV__ bundle that is
// LogBox itself (its dismiss button renders an Image), so the first warning
// crashed the error UI. Image.ios.js is not an option: it getEnforcing's the
// ImageLoader TurboModule, which this engine does not vend yet.
//
// What this renders: a View carrying the image's style (so layout matches;
// no pixels are drawn). Static helpers resolve/reject honestly instead of
// being undefined.
const React = require('react');
const View = require('react-native/Libraries/Components/View/View').default;

function Image(props) {
  return React.createElement(View, {
    style: props.style,
    testID: props.testID,
    nativeID: props.nativeID,
    accessible: props.accessible,
    accessibilityLabel: props.accessibilityLabel ?? props.alt,
  });
}
Image.displayName = 'Image';

const notYet = () =>
  Promise.reject(
    new Error('Image loading is not implemented on react-native-impeller yet'),
  );
Image.getSize = (uri, success, failure) => {
  if (typeof failure === 'function') {
    failure(new Error('Image.getSize is not implemented on react-native-impeller yet'));
    return undefined;
  }
  return notYet();
};
Image.getSizeWithHeaders = (uri, headers, success, failure) =>
  Image.getSize(uri, success, failure);
Image.prefetch = notYet;
Image.prefetchWithMetadata = notYet;
Image.queryCache = () => Promise.resolve({});
Image.resolveAssetSource = (source) =>
  require('react-native/Libraries/Image/resolveAssetSource').default(source);

module.exports = Image;
module.exports.default = Image;
