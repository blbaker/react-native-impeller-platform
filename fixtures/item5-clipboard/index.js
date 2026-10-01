/**
 * item5-clipboard fixture: system Clipboard module + TextInput Cut/Copy/Paste.
 *
 * Two uncontrolled fields stacked in a column (field 1 y 20..56, 'abcdef';
 * field 2 y 76..112, empty), plus two Pressables used ONLY by the JS-round-
 * trip and newline-flattening arms of the gate:
 *
 *   - "setget" (y 130..160): Clipboard.setString('hello é') then
 *     Clipboard.getString().then(s => console.log('GETSTRING=' + s)) --
 *     the ONLY way a headless-style assertion can observe getString()
 *     actually resolving, since nothing else in this fixture reads it back
 *     into anything visible.
 *   - "setnewline" (y 170..200): Clipboard.setString('a\nb\r\nc') -- lets the
 *     gate's newline-flattening arm (e) put a MULTI-LINE string on the
 *     clipboard without a real external clipboard owner.
 *
 * `import {Clipboard}` rather than a default import: RN 0.86's index.js
 * exports Clipboard as a plain CommonJS getter (no `default` key), and
 * reading it logs RN's own one-time deprecation warning -- expected, and
 * harmless to this fixture.
 */
import React from 'react';
import {AppRegistry, Pressable, Text, TextInput, View} from 'react-native';
import {Clipboard} from 'react-native';

function field(n, defaultValue) {
  return (
    <TextInput
      defaultValue={defaultValue}
      onChangeText={t => console.log('ONCHANGE' + n + ' text=' + t)}
      onSelectionChange={e =>
        console.log(
          'ONSEL' +
            n +
            ' start=' +
            e.nativeEvent.selection.start +
            ' end=' +
            e.nativeEvent.selection.end,
        )
      }
      style={{
        width: 300,
        height: 36,
        borderWidth: 1,
        borderColor: '#888888',
        color: '#ffffff',
        fontSize: 14,
        marginTop: 20,
        marginLeft: 20,
      }}
    />
  );
}

function button(top, label, onPress) {
  return (
    <Pressable
      style={{
        position: 'absolute',
        left: 20,
        top,
        width: 180,
        height: 30,
        backgroundColor: '#444444',
      }}
      onPress={onPress}>
      <Text style={{color: '#ffffff', fontSize: 14}}>{label}</Text>
    </Pressable>
  );
}

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      {field(1, 'abcdef')}
      {field(2, '')}
      {button(130, 'setget', () => {
        Clipboard.setString('hello é');
        Clipboard.getString().then(s => console.log('GETSTRING=' + s));
      })}
      {button(170, 'setnewline', () => {
        Clipboard.setString('a\nb\r\nc');
      })}
    </View>
  );
}

AppRegistry.registerComponent('Item5Clipboard', () => Fixture);
