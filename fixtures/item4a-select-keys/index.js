/**
 * desktop-input-gap item 4a fixture: keyboard selection in <TextInput>.
 *
 * Two uncontrolled fields stacked in a column (margins stack: field 1 y
 * 20..56, field 2 y 76..112):
 *   - field 1: "abcdef" (arms a-d, f, g)
 *   - field 2: "abc def" (arm e, Shift+word-left)
 * The gate focuses each with a click PAST the end of the text, so
 * click-to-caret (item 3) leaves the caret at the end.
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
      {field(2, 'abc def')}
    </View>
  );
}

AppRegistry.registerComponent('Item4aSelectKeys', () => Fixture);
