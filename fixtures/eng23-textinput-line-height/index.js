/**
 * ENG-23 TextInput fixture: lineHeight reaches TextInput PAINT, not only <Text>.
 *
 * fontSize 16, black on white, no border. Three multiline fields holding two
 * lines each, plus one single-line field:
 *   y   5  h 60  multiline, lineHeight 16 (1.0 x fontSize) -> lines 16 apart
 *   y  70  h 80  multiline, lineHeight 32 (2.0 x fontSize) -> lines 32 apart
 *   y 155  h 60  multiline, lineHeight unset (control)     -> the face's pitch
 *   y 220  h 60  single-line, lineHeight 40                -> still centred
 * The gate (tools/ci-textinput-line-height.sh) reads the ink bands of each field.
 */
import React from 'react';
import {AppRegistry, TextInput, View} from 'react-native';

const BODY = 'HHHH line one\nHHHH line two';

function field(top, height, lineHeight, multiline, value) {
  const style = {
    position: 'absolute',
    left: 20,
    top,
    width: 240,
    height,
    fontSize: 16,
    color: '#000000',
    backgroundColor: '#ffffff',
    borderWidth: 0,
  };
  if (lineHeight) style.lineHeight = lineHeight;
  return <TextInput multiline={multiline} editable={false} value={value} style={style} />;
}

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      {field(5, 60, 16, true, BODY)}
      {field(70, 80, 32, true, BODY)}
      {field(155, 60, null, true, BODY)}
      {field(220, 60, 40, false, 'HHHH single')}
    </View>
  );
}

AppRegistry.registerComponent('Eng23TextInputLineHeight', () => Fixture);
