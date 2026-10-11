/**
 * desktop-input-gap item 6 fixture: every mouse button reaches JS.
 *
 * A full-size View logs W3C pointer events for any button. Inside it:
 *   - a Pressable (y 20..60, x 20..220) whose onPress logs PRESSED
 *   - a TextInput 'abcdef' (y 80..116, x 20..320)
 * The gate reads the [js] lines.
 */
import React from 'react';
import {AppRegistry, Pressable, Text, TextInput, View} from 'react-native';

function fmt(tag, e) {
  const n = e.nativeEvent;
  return (
    tag +
    ' button=' + n.button +
    ' buttons=' + n.buttons +
    ' detail=' + n.detail +
    ' shift=' + (n.shiftKey ? 1 : 0) +
    ' ctrl=' + (n.ctrlKey ? 1 : 0) +
    ' alt=' + (n.altKey ? 1 : 0) +
    ' meta=' + (n.metaKey ? 1 : 0)
  );
}

function Fixture() {
  return (
    <View
      collapsable={false}
      style={{width: 400, height: 300, backgroundColor: '#111111'}}
      onPointerDown={e => console.log(fmt('POINTERDOWN', e))}
      onPointerUp={e => console.log(fmt('POINTERUP', e))}
      onClick={e => console.log(fmt('CLICK', e))}
      onAuxClick={e => console.log(fmt('AUXCLICK', e))}>
      <Pressable
        onPress={() => console.log('PRESSED')}
        style={{
          width: 200,
          height: 40,
          marginTop: 20,
          marginLeft: 20,
          backgroundColor: '#335577',
        }}>
        <Text style={{color: '#ffffff'}}>press</Text>
      </Pressable>
      <TextInput
        defaultValue="abcdef"
        onFocus={() => console.log('TIFOCUS')}
        onSelectionChange={e =>
          console.log(
            'TISEL start=' +
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
    </View>
  );
}

AppRegistry.registerComponent('Item6MouseButtons', () => Fixture);
