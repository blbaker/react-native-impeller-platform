/**
 * desktop-input-gap item 11 fixture: Tab / Shift+Tab focus traversal.
 *
 * Column of fields (each 300x30, marginTop 10, marginLeft 20):
 *   A 'aaa'                   y 10..40
 *   B 'bbb'                   y 50..80
 *   VIEW focusable            y 90..120 (onFocus/onBlur/onKeyDown)
 *   C 'ccc' editable={false}  y 130..160   (skipped)
 *   D 'ddd' tabIndex={-1}     y 170..200   (skipped)
 *   E 'eee'                   y 210..240
 * Tab order: A B VIEW E (wraps).
 */
import React from 'react';
import {AppRegistry, TextInput, View} from 'react-native';

const box = {width: 300, height: 30, marginTop: 10, marginLeft: 20};

function field(name, value, extra) {
  return (
    <TextInput
      defaultValue={value}
      onFocus={() => console.log('FOCUS ' + name)}
      onBlur={() => console.log('BLUR ' + name)}
      onChangeText={t => console.log('CHANGE ' + name + ' text=' + t)}
      onSelectionChange={e =>
        console.log(
          'SEL ' +
            name +
            ' start=' +
            e.nativeEvent.selection.start +
            ' end=' +
            e.nativeEvent.selection.end,
        )
      }
      style={{
        ...box,
        borderWidth: 1,
        borderColor: '#888888',
        color: '#ffffff',
        fontSize: 14,
      }}
      {...extra}
    />
  );
}

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      {field('A', 'aaa')}
      {field('B', 'bbb')}
      <View
        focusable={true}
        onFocus={() => console.log('FOCUS VIEW')}
        onBlur={() => console.log('BLUR VIEW')}
        onKeyDown={e => console.log('VIEWKEY ' + e.nativeEvent.key)}
        style={{...box, backgroundColor: '#334455'}}
      />
      {field('C', 'ccc', {editable: false})}
      {field('D', 'ddd', {tabIndex: -1})}
      {field('E', 'eee')}
    </View>
  );
}

AppRegistry.registerComponent('Item11TabFocus', () => Fixture);
