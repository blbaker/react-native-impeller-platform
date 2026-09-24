/**
 * ENG item 2 fixture — SUPERSAMPLE-RNSVG.
 *
 * ONE stroked chevron-down (the Tabler `chevron-down` path) in an <Svg> root.
 *
 * ⛔ THIS IS A STROKED, TESSELLATED PATH ON PURPOSE. Impeller gives stroked
 * tessellated paths NO edge-coverage AA (Mac Metal: 2 luminance levels, 0%
 * partial). A FILLED shape would already antialias on some backends and hide
 * the very defect the supersample path exists to fix. The chevron is stroke-
 * only (fill="none"), round caps and joins, so its diagonal edges are exactly
 * where the binary-vs-antialiased difference shows up.
 *
 * ⛔ fill="none" IS MANDATORY. react-native-svg defaults fill to BLACK, so a
 * <Path> with only a stroke is a black-filled box with an outline — which would
 * flood the ink band and swamp the edge-pixel count the gate measures.
 *
 * The chevron is drawn LARGE (a 240x240 box over a 24 viewBox = 10x scale) so
 * the diagonal strokes cross many rows and there are enough edge pixels to make
 * "how many are partial luminance" a stable measurement. Stroke width 1.8 in
 * user units (the design-system icon weight) becomes 18px on screen.
 *
 * A #808080 grey stroke over a #ffffff background: grey (128) sits in the middle
 * of the 0..255 range, so an antialiased edge pixel lands anywhere in 129..254
 * (partial), while a binary edge is either 128 (fully inside the stroke) or 255
 * (fully background) with nothing between. The gate counts the in-between band.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Path} from 'react-native-svg';

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      {/* 240x240 over a 24 viewBox: a 10x uniform scale (xMidYMid meet). */}
      <Svg
        x={20}
        y={20}
        width={240}
        height={240}
        viewBox="0 0 24 24">
        {/* Tabler chevron-down: two diagonals meeting at the bottom point. */}
        <Path
          d="M6 9l6 6l6 -6"
          fill="none"
          stroke="#808080"
          strokeWidth={1.8}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </Svg>
    </View>
  );
}

AppRegistry.registerComponent('EngSupersample', () => Fixture);
