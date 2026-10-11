'use strict';
// <Image> for the `impeller` platform (A19 / SC-30; replaces the parity item
// 12 placeholder View).
//
// WHY a shim: Libraries/Image/Image.js is a self re-export (`import Image from
// './Image'`), so on impeller -- no .impeller.js sibling -- it resolves to
// ITSELF and its default export is undefined. Image.ios.js cannot be used
// either: it getEnforcing's the ImageLoader TurboModule at module load.
//
// This is Image.ios.js's render path: it mounts the RCTImageView host
// component (Fabric "Image", painted by the engine) with `source` as an array,
// resizeMode (objectFit wins, default 'cover') and tintColor (prop or style).
// onLoadStart/onLoad/onError/onLoadEnd and defaultSource ride the native
// component (the engine fires them, SC-31). The statics are Image.ios.js's,
// over the engine's "ImageLoader" module.
const React = require('react');
const interop = (m) => (m && m.default) || m;
const flattenStyle = interop(require('react-native/Libraries/StyleSheet/flattenStyle'));
const StyleSheet = interop(require('react-native/Libraries/StyleSheet/StyleSheet'));
const ImageViewNativeComponent = interop(require('react-native/Libraries/Image/ImageViewNativeComponent'));
const {getImageSourcesFromImageProps} = require('react-native/Libraries/Image/ImageSourceUtils');
const {convertObjectFitToResizeMode} = require('react-native/Libraries/Image/ImageUtils');

const styles = StyleSheet.create({base: {overflow: 'hidden'}});

function Image({ref, ...props}) {
  const source = getImageSourcesFromImageProps(props) || {
    uri: undefined,
    width: undefined,
    height: undefined,
  };
  let style;
  let sources;
  if (Array.isArray(source)) {
    style = [styles.base, props.style];
    sources = source;
  } else {
    const width = source.width ?? props.width;
    const height = source.height ?? props.height;
    style = [{width, height}, styles.base, props.style];
    sources = [source];
  }
  const flat = flattenStyle(style);
  const objectFit = convertObjectFitToResizeMode(flat?.objectFit);
  const resizeMode = objectFit || props.resizeMode || flat?.resizeMode || 'cover';
  const tintColor = props.tintColor ?? flat?.tintColor;
  if (props.children != null) {
    throw new Error(
      'The <Image> component cannot contain children. If you want to render content on top of the image, consider using the <ImageBackground> component or absolute positioning.',
    );
  }
  const {src, 'aria-hidden': ariaHidden, ...rest} = props;
  const accessible = ariaHidden !== true && (props.alt !== undefined ? true : props.accessible);
  return React.createElement(ImageViewNativeComponent, {
    ...rest,
    ref,
    accessible,
    accessibilityLabel: props['aria-label'] ?? props.accessibilityLabel ?? props.alt,
    style,
    resizeMode,
    tintColor,
    source: sources,
  });
}
Image.displayName = 'Image';

const TurboModuleRegistry = require('react-native/Libraries/TurboModule/TurboModuleRegistry');
const loader = () => {
  const m = TurboModuleRegistry.get('ImageLoader');
  if (m == null) throw new Error('ImageLoader native module is not available');
  return m;
};
const settle = (promise, uri, success, failure) => {
  if (typeof success !== 'function') return promise;
  promise
    .then((sizes) => success(sizes.width, sizes.height))
    .catch(failure || (() => console.warn('Failed to get size for image: ' + uri)));
  return undefined;
};
Image.getSize = (uri, success, failure) =>
  settle(
    loader().getSize(uri).then(([width, height]) => ({width, height})),
    uri,
    success,
    failure,
  );
Image.getSizeWithHeaders = (uri, headers, success, failure) =>
  settle(loader().getSizeWithHeaders(uri, headers), uri, success, failure);
Image.prefetch = (url) => loader().prefetchImage(url);
Image.prefetchWithMetadata = (url, queryRootName, rootTag) =>
  loader().prefetchImageWithMetadata(url, queryRootName, rootTag || 0);
Image.queryCache = async (urls) => loader().queryCache(urls);
Image.resolveAssetSource = (source) =>
  require('react-native/Libraries/Image/resolveAssetSource').default(source);

module.exports = Image;
module.exports.default = Image;
