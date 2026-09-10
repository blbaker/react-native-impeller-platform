'use strict';
// ENG-01a. Platform variant handed ONLY to react-native files that branch
// `if (ios) ... else if (android) ...` with no else, and whose iOS arm is the
// desktop-shaped one.
//
// WHY THIS FILE EXISTS AT ALL
// ---------------------------
// TextInput.js does not fail. It BRANCHES ITSELF OUT OF EXISTENCE, exactly the
// way Alert.js did (see Alert.impeller.js). Read the real file:
//
//   line 555  let textInput = null;
//   line 677  if (Platform.OS === 'ios')      { textInput = <RCTSingleline.../> }
//   line 727  else if (Platform.OS === 'android') { textInput = <AndroidTextInput/> }
//            (no else)
//   line 802  return <TextAncestorContext value={true}>{textInput}</TextAncestorContext>
//
// On `impeller` neither arm runs, so a perfectly good <TextInput> renders
// `null` inside a context provider. React mounts nothing, Fabric is never
// asked for a host component, and the log is clean. Registering a
// TextInput ComponentDescriptor in FabricHost.cpp would have changed NOTHING,
// because the JS never reaches C++ at all. That was the whole ENG-01 dispute.
//
// WHY NOT JUST SET Platform.OS = 'ios'
// ------------------------------------
// Because it is a lie the whole bundle would read. Platform.OS === 'impeller'
// is what selects our shims, our .impeller.js extensions, and what app code
// branches on. Flipping it globally to 'ios' would unpick every one of those.
// So the lie is scoped: this module is served ONLY to the specific RN files
// named in IOS_BRANCHED, by resolved-origin path, and every other importer of
// Platform still gets the honest 'impeller'.
//
// Everything except OS is delegated to the real shim, so constants/Version/
// select/isTesting cannot drift between the two copies.
const Platform = require('./Platform.impeller.js');

const PlatformAsIos = Object.create(Platform);
Object.defineProperty(PlatformAsIos, 'OS', {value: 'ios', enumerable: true});
// `select` must keep honouring 'impeller' first — an app that wrote
// Platform.select({impeller: x, ios: y}) means x, and this file is not a
// licence to hand it y. Only the OS string is forged.
PlatformAsIos.select = Platform.select.bind(Platform);

module.exports = PlatformAsIos;
module.exports.default = PlatformAsIos;
