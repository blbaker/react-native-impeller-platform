/**
 * ENG-24 fixture: multiline TextInput keys and growth, single-line caret
 * follow. Every field is CONTROLLED (value + onChangeText), the way the HostApp
 * chat composer is. Each handler logs one machine-readable line:
 *   [js] ENG24 <id> key=<key> shift=<0|1>       onKeyPress
 *   [js] ENG24 <id> change=<JSON of the text>    onChangeText
 *   [js] ENG24 <id> submit n=<count>             onSubmitEditing
 *   [js] ENG24 <id> blur                         onBlur
 *   [js] ENG24 <id> csize w=<w> h=<h>            onContentSizeChange
 * Fields (x 20, width 300, padding 8, fontSize 16, black on white):
 *   NL    y  10 h 90  multiline, submitBehavior 'newline'
 *   SUB   y 110 h 90  multiline, submitBehavior 'submit'
 *   BLUR  y 210 h 60  multiline, submitBehavior 'blurAndSubmit'
 *   LONG  y 280 h 36  single-line (default submitBehavior)
 *   GROW  y 330 h 180 multiline, default submitBehavior (newline)
 */
import React from 'react';
import {AppRegistry, TextInput, View} from 'react-native';

function Field({id, top, height, multiline, submitBehavior}) {
  const [v, setV] = React.useState('');
  const submits = React.useRef(0);
  return (
    <TextInput
      value={v}
      multiline={multiline}
      submitBehavior={submitBehavior}
      onChangeText={t => {
        console.log(`ENG24 ${id} change=${JSON.stringify(t)}`);
        setV(t);
      }}
      onKeyPress={e => {
        const n = e.nativeEvent;
        console.log(`ENG24 ${id} key=${n.key} shift=${n.shiftKey ? 1 : 0}`);
      }}
      onSubmitEditing={() => {
        submits.current += 1;
        console.log(`ENG24 ${id} submit n=${submits.current}`);
      }}
      onBlur={() => console.log(`ENG24 ${id} blur`)}
      onContentSizeChange={e => {
        const s = e.nativeEvent.contentSize;
        console.log(`ENG24 ${id} csize w=${s.width.toFixed(1)} h=${s.height.toFixed(1)}`);
      }}
      style={{
        position: 'absolute',
        left: 20,
        top,
        width: 300,
        height,
        padding: 8,
        fontSize: 16,
        color: '#000000',
        borderWidth: 1,
        borderColor: '#888888',
      }}
    />
  );
}

function Fixture() {
  return (
    <View style={{width: 400, height: 520, backgroundColor: '#ffffff'}}>
      <Field id="NL" top={10} height={90} multiline submitBehavior="newline" />
      <Field id="SUB" top={110} height={90} multiline submitBehavior="submit" />
      <Field id="BLUR" top={210} height={60} multiline submitBehavior="blurAndSubmit" />
      <Field id="LONG" top={280} height={36} multiline={false} />
      <Field id="GROW" top={330} height={180} multiline />
    </View>
  );
}

AppRegistry.registerComponent('Eng24TextInputKeys', () => Fixture);
