/**
 * ENG-23 fixture: <Text> lineHeight reaches MEASURE and PAINT.
 *
 * Three two-line paragraphs at fontSize 16 (HostApp's body-md), black on white:
 *   y  10  lineHeight 16 (1.0 x fontSize)  -> box 32 tall, lines 16 apart
 *   y  80  lineHeight 32 (2.0 x fontSize)  -> box 64 tall, lines 32 apart
 *   y 180  lineHeight unset (control)       -> the face's own metrics
 * The gate (tools/ci-line-height.sh) reads node_frame heights (measure) and the
 * ink bands of each paragraph (paint).
 */
import React from 'react';
import {AppRegistry, Text, View} from 'react-native';

const BODY = 'HHHH line one\nHHHH line two';

function para(top, lineHeight) {
  const style = {position: 'absolute', left: 20, top, fontSize: 16, color: '#000000'};
  if (lineHeight) style.lineHeight = lineHeight;
  return <Text style={style}>{BODY}</Text>;
}

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      {para(10, 16)}
      {para(80, 32)}
      {para(180, null)}
    </View>
  );
}

AppRegistry.registerComponent('Eng23LineHeight', () => Fixture);
