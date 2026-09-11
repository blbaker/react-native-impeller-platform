/**
 * CONCAVE-FILL PROBE (internal request).
 *
 * Does a filled concave <Path> paint its true area, or its convex hull?
 * Five 100x100 cases in a row, green on black, viewBox 0 0 100 100.
 *
 *   A square    M10 10 L90 10 L90 90 L10 90 Z   convex control, 6400
 *   B diamond   M10 50 L50 10 L90 50 L50 90 Z   convex control, 3200
 *   C the L     concave, 4800
 *   D arrowhead concave, 4800
 *   E notched   concave, 3000
 *
 * A convex hull reads 6400 for C and D, and 3200 for E.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Path} from 'react-native-svg';

const MARK = 'rgb(0, 255, 0)';

const DS = [
  'M10 10 L90 10 L90 90 L10 90 Z',
  'M10 50 L50 10 L90 50 L50 90 Z',
  'M10 10 L90 10 L90 50 L50 50 L50 90 L10 90 Z',
  'M10 10 L90 10 L90 90 L50 50 L10 90 Z',
  'M10 50 L30 35 L50 10 L90 50 L50 90 Z',
];

function Fixture() {
  return (
    <View style={{width: 700, height: 300, backgroundColor: 'rgb(0, 0, 0)'}}>
      <View style={{flexDirection: 'row', gap: 20, padding: 20}}>
        {DS.map((d, i) => (
          <Svg key={i} width={100} height={100} viewBox="0 0 100 100">
            <Path d={d} fill={MARK} />
          </Svg>
        ))}
      </View>
    </View>
  );
}

AppRegistry.registerComponent('ConcaveProbe', () => Fixture);
