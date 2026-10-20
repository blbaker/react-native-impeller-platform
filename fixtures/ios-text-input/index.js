/**
 * iOS text-input fixture, so a gate can prove the system keyboard's range
 * edits reach JS: an autocorrection ("teh " -> "the ") in a field with RN's
 * default autocorrect, the same keys left alone in a field with
 * autoCorrect={false} (the field's props reach the keyboard), and a Japanese
 * romaji composition (marked text, then committed: "nihonn" -> "にほん"). Every change is logged as `ios-text <field>=<JSON value>`.
 * autoCapitalize="none" keeps the keyboard's keys lowercase for the UI test;
 * the rest is RN's defaults. Geometry in geometry.js.
 */
import React, {useState} from 'react';
import {AppRegistry, TextInput, View} from 'react-native';

const {background, auto, off, ja} = require('./geometry');

function Field({name, box, autoCorrect}) {
  const [value, setValue] = useState('');
  return (
    <TextInput
      value={value}
      autoCapitalize="none"
      autoCorrect={autoCorrect}
      onFocus={() => console.log('ios-text focus=' + name)}
      onChangeText={v => {
        console.log('ios-text ' + name + '=' + JSON.stringify(v));
        setValue(v);
      }}
      style={{
        position: 'absolute',
        left: box.x,
        top: box.y,
        width: box.width,
        height: box.height,
        backgroundColor: box.color,
        fontSize: 22,
        color: '#000000',
      }}
    />
  );
}

function IosTextInput() {
  return (
    <View style={{flex: 1, backgroundColor: background}}>
      <Field name="auto" box={auto} />
      <Field name="off" box={off} autoCorrect={false} />
      <Field name="ja" box={ja} />
    </View>
  );
}

AppRegistry.registerComponent('IosTextInput', () => IosTextInput);
