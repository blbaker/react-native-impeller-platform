/**
 * iOS input fixture (Phase 4 spike): one Pressable and one TextInput, so a gate
 * can prove a real UIKit touch reaches onPress and real keyboard keys reach
 * onChangeText. Every state change is logged (`ios-input ...`), and the button
 * turns green once pressed, so both the log and the pixels carry the result.
 * Geometry in geometry.js.
 */
import React, {useState} from 'react';
import {AppRegistry, Pressable, TextInput, View} from 'react-native';

const {background, button, input} = require('./geometry');

function IosInput() {
  const [presses, setPresses] = useState(0);
  const [value, setValue] = useState('');
  return (
    <View style={{flex: 1, backgroundColor: background}}>
      <Pressable
        onPress={() => {
          const n = presses + 1;
          console.log('ios-input pressed=' + n);
          setPresses(n);
        }}
        style={{
          position: 'absolute',
          left: button.x,
          top: button.y,
          width: button.width,
          height: button.height,
          backgroundColor: presses > 0 ? button.pressedColor : button.color,
        }}
      />
      <TextInput
        value={value}
        onFocus={() => console.log('ios-input focus=1')}
        onChangeText={v => {
          console.log('ios-input value=' + JSON.stringify(v));
          setValue(v);
        }}
        onSubmitEditing={() => console.log('ios-input submit=' + JSON.stringify(value))}
        style={{
          position: 'absolute',
          left: input.x,
          top: input.y,
          width: input.width,
          height: input.height,
          backgroundColor: input.color,
          fontSize: 22,
          color: '#000000',
        }}
      />
    </View>
  );
}

AppRegistry.registerComponent('IosInput', () => IosInput);
