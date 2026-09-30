/**
 * desktop-input-gap item 2a fixture — real caret + UTF-8 typing.
 *
 * TWO uncontrolled <TextInput>s (defaultValue, no `value` prop — the engine's
 * own edit buffer is the source of truth, matching the ask's "preset to
 * 'abcdef' (defaultValue)"):
 *
 *   - field 1: defaultValue="abcdef". Used for arrow/Home/End/Delete, UTF-8
 *     typing (é / emoji) and the pixel arm.
 *   - field 2: defaultValue="abc def" (WITH a space). Used ONLY for the
 *     word-move arm, which needs a word boundary the first field has none of.
 *
 * Both log onChangeText and onSelectionChange to console (printed by the
 * engine as `[js] ...`), which is the gate's observable — see
 * fixtures/p0-key-events/index.js for the same console-as-evidence pattern.
 * onSelectionChange's start/end are UTF-16 code units, exactly as RN's own
 * TextInputEventEmitter::Metrics::selectionRange defines them.
 */
import React from 'react';
import {AppRegistry, TextInput, View} from 'react-native';

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      <TextInput
        defaultValue="abcdef"
        onChangeText={t => console.log('ONCHANGE1 text=' + t)}
        onSelectionChange={e =>
          console.log(
            'ONSEL1 start=' +
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
          marginTop: 20,
          marginLeft: 20,
        }}
      />
      <TextInput
        defaultValue="abc def"
        onChangeText={t => console.log('ONCHANGE2 text=' + t)}
        onSelectionChange={e =>
          console.log(
            'ONSEL2 start=' +
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
          marginTop: 20, // stacks under field 1: y 76..112, so F2_XY=40,94 is inside
          marginLeft: 20,
        }}
      />
    </View>
  );
}

AppRegistry.registerComponent('Eng2aCaret', () => Fixture);
