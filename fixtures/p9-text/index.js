/**
 * ENG text probe: ellipsis + textTransform.
 *
 * Four labels, each in its own 200x35 row on a white page, so a pixel probe can
 * read each independently:
 *
 *   Row 0 (y 0-35):   numberOfLines={1}, ellipsizeMode default (tail), text far
 *                     wider than 200px. A working ellipsis paints "…" near the
 *                     right edge where a hard clip leaves only glyph/background.
 *   Row 1 (y 35-70):  numberOfLines={1}, ellipsizeMode="clip", same long text.
 *                     Control: NO ellipsis dots.
 *   Row 2 (y 70-105): textTransform="uppercase", text "aceos" (all pure
 *                     x-height lowercase — no ascenders). Uppercased, the glyphs
 *                     reach the CAP line, so ink appears in the top band.
 *   Row 3 (y 105-140): SAME "aceos", NO transform. Control: the top band above
 *                     the x-height stays background. The gate asserts row 2 has
 *                     strictly more top-band ink than row 3.
 */
import React from 'react';
import {AppRegistry, Text, View} from 'react-native';

const LONG =
  'the quick brown fox jumps over the lazy dog and keeps running forever';
const SHORT = 'aceos';

function Fixture() {
  return (
    <View style={{width: 200, height: 140, backgroundColor: '#ffffff'}}>
      <View style={{width: 200, height: 35}}>
        <Text numberOfLines={1} style={{color: '#000000', fontSize: 24}}>
          {LONG}
        </Text>
      </View>
      <View style={{width: 200, height: 35}}>
        <Text
          numberOfLines={1}
          ellipsizeMode="clip"
          style={{color: '#000000', fontSize: 24}}>
          {LONG}
        </Text>
      </View>
      <View style={{width: 200, height: 35}}>
        <Text
          numberOfLines={1}
          style={{color: '#000000', fontSize: 24, textTransform: 'uppercase'}}>
          {SHORT}
        </Text>
      </View>
      <View style={{width: 200, height: 35}}>
        <Text numberOfLines={1} style={{color: '#000000', fontSize: 24}}>
          {SHORT}
        </Text>
      </View>
    </View>
  );
}

AppRegistry.registerComponent('P9Text', () => Fixture);
