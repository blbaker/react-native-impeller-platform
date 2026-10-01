'use strict';
// parity item 7. TextInputState for the `impeller` platform.
//
// WHY THIS EXISTS: RN's TextInputState.js sends the native focus/blur COMMAND
// only inside `if (Platform.OS === 'ios') ... else if (Platform.OS ===
// 'android')`, with no else. It reads Platform through a top-level
// `const Platform = require(...).default`, which Metro's inline-platform
// transform (metro-transform-plugins/src/utils/createInlinePlatformChecks.js)
// rewrites to the BUILD platform string ('impeller') before any resolver shim
// runs. Both branches are then dead code, the minifier deletes them, and
// TextInput ref.focus()/ref.blur() update JS bookkeeping and send nothing.
// The Platform-swap trick that fixes TextInput.js cannot reach this file
// (that file uses an ES import, which the inline pass does not match).
//
// NOT A DELEGATING WRAPPER: there is no .ios.js sibling to delegate to, and
// requiring the real file would redirect straight back here (SHIM_TARGETS
// matches the resolved path). So this is the upstream module with the
// platform branch fixed to the iOS commands, which target the same
// RCTSinglelineTextInputView that TextInput.js mounts on impeller. Every
// importer resolves here, so the focused-input bookkeeping stays single.
const {findNodeHandle} = require('react-native/Libraries/ReactNative/RendererProxy');
const {
  Commands: iOSTextInputCommands,
} = require('react-native/Libraries/Components/TextInput/RCTSingelineTextInputNativeComponent');

let currentlyFocusedInputRef = null;
const inputs = new Set();

function currentlyFocusedInput() {
  return currentlyFocusedInputRef;
}

function currentlyFocusedField() {
  return findNodeHandle(currentlyFocusedInputRef);
}

function focusInput(textField) {
  if (currentlyFocusedInputRef !== textField && textField != null) {
    currentlyFocusedInputRef = textField;
  }
}

function blurInput(textField) {
  if (currentlyFocusedInputRef === textField && textField != null) {
    currentlyFocusedInputRef = null;
  }
}

function focusField() {}
function blurField() {}

function focusTextInput(textField) {
  if (typeof textField === 'number' || textField == null) return;
  const fieldCanBeFocused =
    currentlyFocusedInputRef !== textField &&
    textField.currentProps?.editable !== false;
  if (!fieldCanBeFocused) return;
  focusInput(textField);
  iOSTextInputCommands.focus(textField);
}

function blurTextInput(textField) {
  if (typeof textField === 'number') return;
  if (currentlyFocusedInputRef === textField && textField != null) {
    blurInput(textField);
    iOSTextInputCommands.blur(textField);
  }
}

function registerInput(textField) {
  if (typeof textField === 'number') return;
  inputs.add(textField);
}

function unregisterInput(textField) {
  if (typeof textField === 'number') return;
  inputs.delete(textField);
}

function isTextInput(textField) {
  if (typeof textField === 'number') return false;
  return inputs.has(textField);
}

const TextInputState = {
  currentlyFocusedInput,
  focusInput,
  blurInput,
  currentlyFocusedField,
  focusField,
  blurField,
  focusTextInput,
  blurTextInput,
  registerInput,
  unregisterInput,
  isTextInput,
};

module.exports = TextInputState;
module.exports.default = TextInputState;
