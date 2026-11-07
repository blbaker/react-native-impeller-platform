'use strict';
// ENG-01d. Keep `Platform.OS` a RUNTIME read in the files withImpeller hands
// the as-ios Platform, so the build-time inliners cannot delete their iOS arm.
//
// WHY THE RESOLVER FIX ALONE WAS NOT ENOUGH
// -----------------------------------------
// ENG-01a/01c (index.js, IOS_BRANCHED_*) give TextInput.js a Platform module
// whose OS is 'ios'. That only helps if TextInput.js READS Platform.OS when it
// runs. Two transforms replace the read with the BUILD platform string first:
//
//   - babel-preset-expo, production only: its define plugin rewrites every
//     `Platform.OS` member expression to 'impeller' (configs/expo.js
//     `inlines['Platform.OS'] = platform`), and minify-platform-select does the
//     same to `Platform.select(...)`. Both match on the identifier NAME.
//   - Metro's own inlinePlugin (metro-transform-plugins
//     createInlinePlatformChecks) when imports reach it as ESM
//     (experimentalImportSupport): it matches a top-level binding named
//     `Platform`.
//
// After that, `if ('impeller' === 'ios')` is constant-folded away and
// TextInput.js renders null: no native field, no error, clean log. Measured on
// a touchscreen kiosk app (Expo 57, NativeWind 5): scene_nodes=3 for a screen of
// five TextInputs. A plain RN CLI bundle never hit this, because babel's
// commonjs transform turns `Platform` into `_Platform.default` before Metro's
// inliner looks, which is why every RN CLI gate stayed green.
//
// THE FIX
// -------
// Wrap the app's babel transformer. For the in-scope files only (the same
// tables the resolver uses, so the two halves can never disagree), prepend a
// plugin that renames the Platform binding before any other plugin visits the
// file. Both inliners match on the name `Platform`, so a renamed binding is
// left alone and stays a runtime read of whatever module the resolver handed
// in. Every other file is passed through untouched and keeps its inlining:
// Platform.OS is still 'impeller' for the rest of the bundle.
//
// The upstream transformer path reaches Metro's worker processes through an
// environment variable set by withImpeller (the worker gets no Metro config,
// only `babelTransformerPath`). Workers are forked after the config loads, so
// they inherit it.
const crypto = require('crypto');
const fs = require('fs');

const UPSTREAM_ENV = 'RNI_IMPELLER_UPSTREAM_BABEL_TRANSFORMER';
// Bump if the plugin's output changes without this file changing size/content
// (it cannot today: the file hash below already covers that).
const CACHE_VERSION = 'rni-runtime-platform-1';

function upstream() {
  const target = process.env[UPSTREAM_ENV];
  if (!target) {
    throw new Error(
      'react-native-impeller-platform: babel-transformer.js was loaded without an upstream ' +
        'transformer. Use it only through withImpeller(), which sets ' +
        UPSTREAM_ENV +
        '.',
    );
  }
  return require(target);
}

// `import Platform from '../../Utilities/Platform'` or a top-level
// `const Platform = require('../../Utilities/Platform')`.
const PLATFORM_SOURCE = /(^|\/)Utilities\/Platform(\.js)?$/;

function platformSourceOf(binding) {
  if (!binding) return null;
  const p = binding.path;
  if (binding.kind === 'module' && p.parentPath && p.parentPath.isImportDeclaration()) {
    return p.parentPath.node.source.value;
  }
  if (p.isVariableDeclarator()) {
    const init = p.node.init;
    if (
      init &&
      init.type === 'CallExpression' &&
      init.callee.type === 'Identifier' &&
      init.callee.name === 'require' &&
      init.arguments.length === 1 &&
      init.arguments[0].type === 'StringLiteral'
    ) {
      return init.arguments[0].value;
    }
  }
  return null;
}

function runtimePlatformPlugin() {
  return {
    name: 'react-native-impeller-runtime-platform-os',
    visitor: {
      // Program ENTER: runs before any plugin visits a MemberExpression, and
      // config `plugins` run before preset plugins, so the rename lands first.
      Program(programPath) {
        const binding = programPath.scope.getBinding('Platform');
        const source = platformSourceOf(binding);
        if (!source || !PLATFORM_SOURCE.test(source)) return;
        programPath.scope.rename('Platform', programPath.scope.generateUid('rniRuntimePlatform'));
      },
    },
  };
}

function transform(args) {
  const target = upstream();
  // Lazy: index.js is the source of truth for which files get the as-ios
  // Platform, and requiring it here keeps both halves on ONE table.
  const {keepsRuntimePlatform} = require('./index.js');
  if (!args || !keepsRuntimePlatform(args.filename, args.options && args.options.platform)) {
    return target.transform(args);
  }
  return target.transform({
    ...args,
    plugins: [runtimePlatformPlugin, ...(args.plugins || [])],
  });
}

function getCacheKey(...rest) {
  const target = upstream();
  const own = crypto
    .createHash('sha1')
    .update(CACHE_VERSION)
    .update(fs.readFileSync(__filename))
    .update(fs.readFileSync(require.resolve('./index.js')))
    .digest('hex');
  const theirs = typeof target.getCacheKey === 'function' ? target.getCacheKey(...rest) : '';
  return [own, theirs].join('$');
}

module.exports = {
  transform,
  getCacheKey,
  runtimePlatformPlugin,
  UPSTREAM_ENV,
};
