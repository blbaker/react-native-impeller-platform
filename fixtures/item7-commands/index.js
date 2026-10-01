/**
 * desktop-input-gap / parity item 7 fixture: view commands.
 *
 * Layout (column, width 400):
 *   ScrollView 300x100 at y 0..100 holding 10 rows of 40 (content 400 tall)
 *   button row y 110..140: [scrollTo40] [toEnd] [focusB] [blurB]   (90 wide)
 *   button row y 150..180: [selectB] [setText] [ctlSel]
 *     ctlSel sets C's `selection` prop 400 ms later, so the gate can click C
 *     first (a click on a button blurs any focused field, as on desktop).
 *   field A 'aaaa' y 190..220, field B 'bbbbbb' y 230..260
 *   field C (controlled value + selection state) y 265..295
 * Every button logs nothing itself; the gate reads the native-side
 * command/caret/selection lines and the JS onScroll/onFocus/onSelectionChange.
 */
import React, {useRef, useState} from 'react';
import {AppRegistry, Pressable, ScrollView, Text, TextInput, View} from 'react-native';

function Btn({x, y, label, onPress}) {
  return (
    <Pressable
      onPress={onPress}
      style={{
        position: 'absolute',
        left: x,
        top: y,
        width: 90,
        height: 30,
        backgroundColor: '#335577',
      }}>
      <Text style={{color: '#ffffff', fontSize: 10}}>{label}</Text>
    </Pressable>
  );
}

const fieldStyle = {
  position: 'absolute',
  left: 20,
  width: 300,
  height: 30,
  borderWidth: 1,
  borderColor: '#888888',
  color: '#ffffff',
  fontSize: 14,
};

function Fixture() {
  const sv = useRef(null);
  const b = useRef(null);
  const [cValue, setCValue] = useState('cccccc');
  const [cSel, setCSel] = useState(undefined);
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      <ScrollView
        ref={sv}
        style={{position: 'absolute', left: 0, top: 0, width: 300, height: 100}}
        onScroll={e =>
          console.log('ONSCROLL y=' + Math.round(e.nativeEvent.contentOffset.y))
        }>
        {Array.from({length: 10}, (_, i) => (
          <View
            key={i}
            style={{height: 40, backgroundColor: i % 2 ? '#224422' : '#442222'}}
          />
        ))}
      </ScrollView>
      <Btn x={0} y={110} label="scrollTo40" onPress={() => sv.current.scrollTo({y: 40, animated: false})} />
      <Btn x={100} y={110} label="toEnd" onPress={() => sv.current.scrollToEnd({animated: false})} />
      <Btn x={200} y={110} label="focusB" onPress={() => b.current.focus()} />
      <Btn x={300} y={110} label="blurB" onPress={() => b.current.blur()} />
      <Btn x={0} y={150} label="selectB" onPress={() => b.current.setSelection(1, 4)} />
      <Btn x={100} y={150} label="setText" onPress={() => setCValue('hello')} />
      <Btn
        x={200}
        y={150}
        label="ctlSel"
        onPress={() => setTimeout(() => setCSel({start: 2, end: 4}), 400)}
      />
      <TextInput
        defaultValue="aaaa"
        onFocus={() => console.log('FOCUS A')}
        onBlur={() => console.log('BLUR A')}
        style={{...fieldStyle, top: 190}}
      />
      <TextInput
        ref={b}
        defaultValue="bbbbbb"
        onFocus={() => console.log('FOCUS B')}
        onBlur={() => console.log('BLUR B')}
        onSelectionChange={e =>
          console.log(
            'SEL B start=' +
              e.nativeEvent.selection.start +
              ' end=' +
              e.nativeEvent.selection.end,
          )
        }
        style={{...fieldStyle, top: 230}}
      />
      <TextInput
        value={cValue}
        selection={cSel}
        onChangeText={setCValue}
        onSelectionChange={e =>
          console.log(
            'SEL C start=' +
              e.nativeEvent.selection.start +
              ' end=' +
              e.nativeEvent.selection.end,
          )
        }
        style={{...fieldStyle, top: 265}}
      />
    </View>
  );
}

AppRegistry.registerComponent('Item7Commands', () => Fixture);
