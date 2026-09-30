/**
 * desktop-input-gap item 4b fixture: mouse selection in <TextInput>.
 *
 * Two uncontrolled fields stacked in a column (field 1 y 20..56, field 2
 * y 76..112):
 *   - field 1: "abcdef" (drag, Shift+click, triple click)
 *   - field 2: "abc def ghi" (double click selects a word, word-drag)
 */
import React from 'react';
import {AppRegistry, TextInput, View} from 'react-native';

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

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      {field(1, 'abcdef')}
      {field(2, 'abc def ghi')}
    </View>
  );
}

AppRegistry.registerComponent('Item4bSelectMouse', () => Fixture);
