/**
 * P9-E fixture — the basic SVG shapes.
 *
 * Rect, Circle, Ellipse and Line are converted to path data in the engine and
 * painted by the same code as <Path>. This fixture proves each one MOUNTS and
 * lands where its own props say it should.
 *
 * ⛔ GEOMETRY IS THE ASSERTION, NOT PRESENCE.
 *
 * Every shape here could be drawn by a renderer that got the conversion wrong
 * -- a circle at the wrong centre, an ellipse that came out circular, a rect
 * that ignored its corner radii -- and every one of those still "paints
 * something". So each shape gets a distinct colour and the gate probes points
 * that only the CORRECT geometry can satisfy:
 *
 *   rect     interior + a corner that must be EMPTY (rounded, not square)
 *   circle   centre filled, and a corner of its bounding box empty
 *   ellipse  wide but not tall: a point inside the x-radius but outside the
 *            y-radius must be background (catches rx/ry being swapped or a
 *            circle being drawn instead)
 *   line     a stroked open path -- has no interior to fill at all
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Circle, Ellipse, Line, Rect} from 'react-native-svg';

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      <Svg width={400} height={300} viewBox="0 0 400 300">
        {/* RECT with corner radii. The square corner at (20,20) must be EMPTY
            if rx/ry were honoured. */}
        <Rect x={20} y={20} width={100} height={70} rx={20} ry={20} fill="#ff0000" />

        {/* CIRCLE, r=35 centred (215,55). Its bounding-box corner (182,22)
            must be empty. */}
        <Circle cx={215} cy={55} r={35} fill="#0000ff" />

        {/* ELLIPSE, rx=55 ry=25 centred (80,200). Deliberately NOT circular:
            (80,175) is outside the y-radius but well inside the x-radius, so
            a circle drawn with r=rx would wrongly fill it. */}
        <Ellipse cx={80} cy={200} rx={55} ry={25} fill="#008000" />

        {/* LINE, horizontal, 10px magenta. An open path: stroke only. */}
        <Line x1={170} y1={200} x2={300} y2={200} stroke="#ff00ff" strokeWidth={10} />
      </Svg>
    </View>
  );
}

AppRegistry.registerComponent('P9Shapes', () => Fixture);
