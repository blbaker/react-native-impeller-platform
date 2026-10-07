/**
 * ENG-13 fixture: strokeDasharray / strokeDashoffset on RNSVG shapes.
 *
 * Black strokes on white, so every check is "ink or not" on a known line.
 * Read by tools/svg-dash-measure.py; the rows and what they must paint:
 *
 *   A  y=20   CONTROL, no dasharray          one solid run 20..380
 *   B  y=45   [20, 10] (array form)          12 dashes of 20, gaps of 10
 *   C  y=70   "20 10", offset 5              first dash 20..35 (15 long)
 *   D  y=95   "20 10", offset -5             first ink at 25 (wraps to 25)
 *   E  y=120  "15 5 5" (odd, repeated)       on 15, off 5, on 5, off 15, on 5 ...
 *   F  y=150  "0 12", round caps             31 dots, centres every 12
 *   G  y=175  "0 12", butt caps              NOTHING (zero-length, butt)
 *   H  y=200  [10, -5] (negative = invalid)  solid run
 *   I  y=225  "0 0" (zero sum = invalid)     solid run
 *   J  circle r=50 at (100,330), "10 10"     16 separate dashes (closed curve)
 *   K  rect 220,290 150x80, "30 10"          11 dashes; the LAST dash joins the
 *                                            first through the top-left corner
 *   L  two identical small <Svg>s, offset 0 vs 10. Same content, so the
 *      per-icon texture cache (--supersample-rnsvg 1) would reuse one for
 *      the other if the dash were not part of its key.
 *   M  the ENGINE-LEDGER acceptance case ("grace ring"): three r=25 rings,
 *      strokeDasharray [C, C] with C = 2*pi*25, offsets 0, C/4 and 3C/4.
 *      The painted ring must shrink as the offset rises: full, 3/4, 1/4.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Circle, Line, Rect} from 'react-native-svg';

const row = (y, props) => (
  <Line x1={20} y1={y} x2={380} y2={y} stroke="#000000" strokeWidth={6} {...props} />
);

function Small({offset}) {
  return (
    <Svg width={180} height={30} viewBox="0 0 180 30">
      <Line x1={10} y1={15} x2={170} y2={15} stroke="#000000" strokeWidth={6}
        strokeDasharray="10 10" strokeDashoffset={offset} />
    </Svg>
  );
}

const RING_C = 2 * Math.PI * 25;

function Ring({offset}) {
  return (
    <Svg width={60} height={60} viewBox="0 0 60 60">
      <Circle cx={30} cy={30} r={25} fill="none" stroke="#000000"
        strokeWidth={4} strokeDasharray={[RING_C, RING_C]}
        strokeDashoffset={offset} />
    </Svg>
  );
}

function Fixture() {
  return (
    <View style={{width: 400, height: 500, backgroundColor: '#ffffff'}}>
      <Svg width={400} height={400} viewBox="0 0 400 400">
        {row(20, {})}
        {row(45, {strokeDasharray: [20, 10]})}
        {row(70, {strokeDasharray: '20 10', strokeDashoffset: 5})}
        {row(95, {strokeDasharray: '20 10', strokeDashoffset: -5})}
        {row(120, {strokeDasharray: '15 5 5'})}
        {row(150, {strokeDasharray: '0 12', strokeLinecap: 'round'})}
        {row(175, {strokeDasharray: '0 12'})}
        {row(200, {strokeDasharray: [10, -5]})}
        {row(225, {strokeDasharray: '0 0'})}
        <Circle cx={100} cy={330} r={50} fill="none" stroke="#000000"
          strokeWidth={4} strokeDasharray="10 10" />
        <Rect x={220} y={290} width={150} height={80} fill="none"
          stroke="#000000" strokeWidth={4} strokeDasharray="30 10" />
      </Svg>
      <View style={{flexDirection: 'row', paddingLeft: 20}}>
        <Small offset={0} />
        <View style={{width: 20}} />
        <Small offset={10} />
      </View>
      <View style={{flexDirection: 'row', paddingLeft: 20, marginTop: 10}}>
        <Ring offset={0} />
        <View style={{width: 40}} />
        <Ring offset={RING_C / 4} />
        <View style={{width: 40}} />
        <Ring offset={(3 * RING_C) / 4} />
      </View>
    </View>
  );
}

AppRegistry.registerComponent('Eng13SvgDash', () => Fixture);
