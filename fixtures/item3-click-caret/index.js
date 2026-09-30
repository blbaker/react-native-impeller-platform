/**
 * desktop-input-gap item 3 fixture: click-to-caret.
 *
 * Two uncontrolled <TextInput>s stacked in a column:
 *   - field 1: defaultValue "abcdef", y 20..56. Boundary aiming, left/right
 *     half, before-start / past-end, and the "click the already-focused field"
 *     arm (typing must survive a second click).
 *   - field 2: defaultValue "a\u00e9bc" (e-acute is 2 UTF-8 bytes, 1 UTF-16
 *     unit), y 76..112. A click after the e-acute must give UTF-8 byte offset
 *     3 and UTF-16 selection 2.
 * Console lines are the gate's observable (the engine prints them as [js] ...).
 */
import React from 'react';
import {AppRegistry, TextInput, View} from 'react-native';

function field(n, defaultValue) {
  return (
    <TextInput
      defaultValue={defaultValue}
      onFocus={() => console.log('ONFOCUS' + n)}
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

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      {field(1, 'abcdef')}
      {field(2, 'a\u00e9bc')}
    </View>
  );
}

AppRegistry.registerComponent('Item3ClickCaret', () => Fixture);
