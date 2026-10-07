/**
 * ENG-25 fixture: a MULTILINE TextInput whose text soft-wraps.
 *
 * The macOS tester's probe verbatim (200 x 120 box, fontSize 16, lineHeight 20,
 * white on #222), inside a black root so the box edges are clear in a
 * screenshot. The 20 pt padding puts the box at (20,20)-(220,140) in a
 * 1x window. Handlers log one machine-readable line each:
 *   [js] ENG25 change=<JSON of the text>     onChangeText
 *   [js] ENG25 sel=<start>,<end>              onSelectionChange
 */
import React, { useState } from 'react';
import { AppRegistry, View, TextInput } from 'react-native';

function P() {
  const [v, setV] = useState(
    'alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike',
  );
  return (
    <View style={{ flex: 1, backgroundColor: '#000' }}>
      <View style={{ padding: 20 }}>
        <TextInput
          testID="ml"
          multiline
          value={v}
          onChangeText={(t) => {
            console.log('ENG25 change=' + JSON.stringify(t));
            setV(t);
          }}
          onSelectionChange={(e) =>
            console.log(
              'ENG25 sel=' +
                e.nativeEvent.selection.start +
                ',' +
                e.nativeEvent.selection.end,
            )
          }
          style={{
            width: 200,
            height: 120,
            fontSize: 16,
            lineHeight: 20,
            color: '#fff',
            backgroundColor: '#222',
          }}
        />
      </View>
    </View>
  );
}

AppRegistry.registerComponent('Eng25MultilineCaret', () => P);
