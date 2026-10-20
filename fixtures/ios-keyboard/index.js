/**
 * iOS keyboard fixture: a TextInput and a green footer at the bottom of a
 * KeyboardAvoidingView (behavior="padding"). When the keyboard comes up, RN's
 * own KeyboardAvoidingView must pad them above it; when it goes, back down.
 * Logs every Keyboard event (`ios-kb <event> {...}`) and every footer layout
 * (`ios-kb footer {...}`), so a gate can compare the two. Geometry in
 * geometry.js.
 */
import React, {useEffect} from 'react';
import {AppRegistry, Keyboard, KeyboardAvoidingView, TextInput, View} from 'react-native';

const {background, input, footer} = require('./geometry');

const EVENTS = ['keyboardWillShow', 'keyboardDidShow', 'keyboardWillHide', 'keyboardDidHide'];

function IosKeyboard() {
  useEffect(() => {
    const subs = EVENTS.map(name =>
      Keyboard.addListener(name, e => {
        const end = (e && e.endCoordinates) || {};
        console.log(
          'ios-kb ' +
            name +
            ' ' +
            JSON.stringify({
              screenY: end.screenY,
              height: end.height,
              duration: e && e.duration,
              easing: e && e.easing,
            }),
        );
      }),
    );
    return () => subs.forEach(s => s.remove());
  }, []);
  return (
    <KeyboardAvoidingView behavior="padding" style={{flex: 1, backgroundColor: background}}>
      <View style={{flex: 1}} />
      <TextInput
        autoCapitalize="none"
        onFocus={() => console.log('ios-kb focus=1')}
        style={{height: input.height, backgroundColor: input.color, fontSize: 22}}
      />
      <View
        onLayout={e => {
          const l = e.nativeEvent.layout;
          console.log('ios-kb footer ' + JSON.stringify({y: l.y, height: l.height}));
        }}
        style={{height: footer.height, backgroundColor: footer.color}}
      />
    </KeyboardAvoidingView>
  );
}

AppRegistry.registerComponent('IosKeyboard', () => IosKeyboard);
