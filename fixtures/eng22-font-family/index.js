/**
 * ENG-22 fixture: <Text>/<TextInput> fontFamily reaches PAINT, not just measure.
 *
 * Geist Mono is monospaced: every glyph advances 600/1000 em, so at fontSize 20
 * ten 'i' and ten 'M' both advance 120 px. A proportional fallback face makes
 * 'i' roughly a third the width of 'M'. So the ink width of "iiiiiiiiii"
 * divided by "MMMMMMMMMM" is ~1 in the right face and ~0.3 in the wrong one,
 * on any font stack, with no pixel-exact glyph compare.
 *
 * Rows (absolute, so each <Text> box is exactly its MEASURED width):
 *   y  10  Text      Geist Mono  iiiiiiiiii
 *   y  45  Text      Geist Mono  MMMMMMMMMM
 *   y  80  Text      default     iiiiiiiiii   (control: proves the face differs)
 *   y 115  Text      default     MMMMMMMMMM
 *   y 150  TextInput Geist Mono  iiiiiiiiii   (field 300 x 36)
 *   y 195  TextInput Geist Mono  MMMMMMMMMM
 * Black ink on white. The gate (tools/ci-font-family.sh) reads the PPM.
 */
import React from 'react';
import {AppRegistry, Text, TextInput, View} from 'react-native';

const MONO = 'Geist Mono';
const I10 = 'iiiiiiiiii';
const M10 = 'MMMMMMMMMM';

function label(top, text, family) {
  const style = {position: 'absolute', left: 20, top, fontSize: 20, color: '#000000'};
  if (family) style.fontFamily = family;
  return <Text style={style}>{text}</Text>;
}

function field(top, value) {
  return (
    <TextInput
      defaultValue={value}
      style={{
        position: 'absolute',
        left: 20,
        top,
        width: 300,
        height: 36,
        fontSize: 20,
        fontFamily: MONO,
        color: '#000000',
      }}
    />
  );
}

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      {label(10, I10, MONO)}
      {label(45, M10, MONO)}
      {label(80, I10, null)}
      {label(115, M10, null)}
      {field(150, I10)}
      {field(195, M10)}
    </View>
  );
}

AppRegistry.registerComponent('Eng22FontFamily', () => Fixture);
