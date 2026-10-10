'use strict';
// Button shim for the `impeller` platform (SC-24).
//
// RN's Button.js picks its look with Platform.OS / Platform.select, which Metro
// inlines to 'impeller' at build time: the android branch is not taken (no
// TouchableNativeFeedback) but neither is the ios one, so `styles.button` is
// undefined and a `color` prop becomes a filled backgroundColor block with the
// default black title. This copy hard-wires the iOS look: blue (or `color`)
// title, no filled block, TouchableOpacity.

const React = require('react');
const interop = (m) => (m && m.default) || m;
const StyleSheet = interop(require('react-native/Libraries/StyleSheet/StyleSheet'));
const Text = interop(require('react-native/Libraries/Text/Text'));
const TouchableOpacity = interop(require('react-native/Libraries/Components/Touchable/TouchableOpacity'));
const View = interop(require('react-native/Libraries/Components/View/View'));

const Button = ({ref, ...props}) => {
  const {
    accessibilityLabel,
    accessibilityState,
    'aria-busy': ariaBusy,
    'aria-checked': ariaChecked,
    'aria-disabled': ariaDisabled,
    'aria-expanded': ariaExpanded,
    'aria-label': ariaLabel,
    'aria-selected': ariaSelected,
    accessible,
    accessibilityActions,
    accessibilityHint,
    accessibilityLanguage,
    onAccessibilityAction,
    importantForAccessibility,
    color,
    disabled: disabledProp,
    onPress,
    testID,
    title,
    touchSoundDisabled,
  } = props;
  const textStyles = [styles.text];
  if (color) {
    textStyles.push({color});
  }

  let state = {
    busy: ariaBusy ?? accessibilityState?.busy,
    checked: ariaChecked ?? accessibilityState?.checked,
    disabled: ariaDisabled ?? accessibilityState?.disabled,
    expanded: ariaExpanded ?? accessibilityState?.expanded,
    selected: ariaSelected ?? accessibilityState?.selected,
  };
  const disabled = disabledProp != null ? disabledProp : state.disabled;
  if (disabled !== state.disabled) {
    state = {...state, disabled};
  }
  if (disabled) {
    textStyles.push(styles.textDisabled);
  }

  if (typeof title !== 'string') {
    throw new Error('The title prop of a Button must be a string');
  }

  return React.createElement(
    TouchableOpacity,
    {
      accessible,
      accessibilityActions,
      onAccessibilityAction,
      accessibilityLabel: ariaLabel || accessibilityLabel,
      accessibilityHint,
      accessibilityLanguage,
      accessibilityRole: 'button',
      accessibilityState: state,
      importantForAccessibility:
        importantForAccessibility === 'no' ? 'no-hide-descendants' : importantForAccessibility,
      testID,
      disabled,
      onPress,
      touchSoundDisabled,
      ref,
    },
    React.createElement(
      View,
      null,
      React.createElement(Text, {style: textStyles, disabled}, title),
    ),
  );
};

Button.displayName = 'Button';

const styles = StyleSheet.create({
  text: {textAlign: 'center', margin: 8, color: '#007AFF', fontSize: 18},
  textDisabled: {color: '#cdcdcd'},
});

module.exports = Button;
module.exports.default = Button;
