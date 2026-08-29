/**
 * P9-D fixture — stroke.
 *
 * ⛔ fill="none" IS MANDATORY FOR A HOLLOW SHAPE, AND OMITTING `fill` IS NOT
 * THE SAME THING.
 *
 * The SVG spec defaults `fill` to BLACK, and react-native-svg implements that
 * literally (extractFill.ts: `const defaultFill = { type: 0, payload:
 * processColor('black') }`, with the comment "we want the default value of
 * fill to be black to match the spec"). So a <Path> with only a `stroke` prop
 * is a BLACK-FILLED shape with an outline — correct, and not what a
 * "stroke-only" test wants. Writing this fixture without fill="none" produced
 * solid black boxes that looked exactly like a renderer bug.
 *
 * Four probes, each isolating a way stroke goes wrong:
 *
 *   1. STROKE-ONLY   fill="none". A renderer that gates painting on "has a
 *                    fill" draws NOTHING here while looking perfect elsewhere.
 *   2. FILL+STROKE   different colours on purpose. StrokeAndFill (one paint,
 *                    one colour) would paint the outline in the FILL's colour;
 *                    only two independent draws get this right.
 *   3. WIDTH         a much thicker stroke. Catches a hardcoded/ignored width,
 *                    which is invisible whenever the default happens to be 1.
 *   4. OPACITY       strokeOpacity independent of fillOpacity, so a renderer
 *                    that reuses the fill's alpha for the stroke is caught.
 *
 * All four use the SAME box geometry so nothing can differ for a reason other
 * than the stroke props.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Path} from 'react-native-svg';

const box = (x, y, w, h) =>
  `M${x} ${y} L${x + w} ${y} L${x + w} ${y + h} L${x} ${y + h} Z`;

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      <Svg width={400} height={300} viewBox="0 0 400 300">
        {/* 1. STROKE-ONLY — fill="none", so the interior must stay background. */}
        <Path
          d={box(20, 20, 80, 60)}
          fill="none"
          stroke="#ff0000"
          strokeWidth={6}
        />

        {/* 2. FILL + STROKE, DIFFERENT COLOURS. Green interior, blue edge.
            If the edge comes out green, fill and stroke are sharing a paint. */}
        <Path
          d={box(160, 20, 80, 60)}
          fill="#008000"
          stroke="#0000ff"
          strokeWidth={6}
        />

        {/* 3. WIDTH — same shape, a 16px magenta edge, hollow. */}
        <Path
          d={box(20, 150, 80, 60)}
          fill="none"
          stroke="#ff00ff"
          strokeWidth={16}
        />

        {/* 4. STROKE OPACITY — black at 0.25, over white. Must resolve to a
            light grey, NOT black, and NOT the fill's opacity. */}
        <Path
          d={box(160, 150, 80, 60)}
          fill="none"
          stroke="#000000"
          strokeWidth={12}
          strokeOpacity={0.25}
        />
      </Svg>
    </View>
  );
}

AppRegistry.registerComponent('P9Stroke', () => Fixture);
