/**
 * CONCAVE-FILL PROBE (internal request).
 *
 * Does a filled concave <Path> paint its true area, or its convex hull?
 * Five 100x100 cases in a row, green on black, viewBox 0 0 100 100.
 *
 *   A square    M10 10 L90 10 L90 90 L10 90 Z   convex control, 6400
 *   B diamond   M10 50 L50 10 L90 50 L50 90 Z   convex control, 3200
 *   C the L     concave, 4800   hull 5600   bbox 6400
 *   D arrowhead concave, 4800   hull 6400   bbox 6400
 *   E deep-V    concave, 4600   hull 6400   bbox 6400
 *
 * ⚠️ E WAS A DEAD ARM AND IS NOT ANY MORE. The old E was a notched pentagon
 * `M10 50 L30 35 L50 10 L90 50 L50 90 Z`. Its true area is 3100 (the ledger
 * said 3000, which was itself wrong) and its convex hull is 3200 -- the notch
 * at (30,35) sits almost ON the hull edge, so hull and truth differ by 3.2%.
 * Every tolerance wide enough to absorb rasteriser edge rounding also swallows
 * the hull answer, so E graded TRUE-AREA whether the engine filled the path or
 * its hull. An arm that cannot fail is not evidence. E is now a deep V whose
 * hull and bounding box are BOTH 6400 against a true 4600: +39% either way,
 * so one arm now rules out hull AND bbox at once.
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
  'M10 10 L50 55 L90 10 L90 90 L10 90 Z',
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
