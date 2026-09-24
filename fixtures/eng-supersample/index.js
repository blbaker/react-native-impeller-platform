/**
 * ENG item 2 fixture — SUPERSAMPLE-RNSVG.
 *
 * THREE stroked icons in three <Svg> roots:
 *   1. chevron-down  (the Tabler `chevron-down` path)
 *   2. chevron-down  — IDENTICAL to #1: same `d`, same size, same stroke. This
 *      is deliberate. Its offscreen texture is keyed by CONTENT+pixel size, so
 *      the second render is a svgCache_ HIT and its subtree is NEVER walked by
 *      the offscreen render. painted_nodes must count it anyway (the fix), or
 *      the tally silently under-counts by the icon's subtree size on a cache
 *      hit — measured task 768: N=0=534 vs N=4=531.
 *   3. chevron-up    — a UNIQUE path, so a guaranteed cache MISS. Proves the
 *      count is right on the miss arm too, not only the hit arm.
 *
 * ⛔ THESE ARE STROKED, TESSELLATED PATHS ON PURPOSE. Impeller gives stroked
 * tessellated paths NO edge-coverage AA (Mac Metal: 2 luminance levels, 0%
 * partial). A FILLED shape would already antialias on some backends and hide
 * the very defect the supersample path exists to fix. Stroke-only (fill="none"),
 * round caps and joins, so the diagonal edges are exactly where the binary-vs-
 * antialiased difference shows up.
 *
 * ⛔ fill="none" IS MANDATORY. react-native-svg defaults fill to BLACK, so a
 * <Path> with only a stroke is a black-filled box with an outline — which would
 * flood the ink band and swamp the edge-pixel count the gate measures.
 *
 * Each icon is drawn LARGE (a 240x240 box over a 24 viewBox = 10x scale) so the
 * diagonal strokes cross many rows and there are enough edge pixels to make
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

function Icon({x, y, d}) {
  // 240x240 over a 24 viewBox: a 10x uniform scale (xMidYMid meet).
  return (
    <Svg x={x} y={y} width={240} height={240} viewBox="0 0 24 24">
      <Path
        d={d}
        fill="none"
        stroke="#808080"
        strokeWidth={1.8}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </Svg>
  );
}

function Fixture() {
  const CHEVRON_DOWN = 'M6 9l6 6l6 -6';
  const CHEVRON_UP = 'M6 15l6 -6l6 6';
  return (
    <View style={{width: 760, height: 300, backgroundColor: '#ffffff'}}>
      {/* #1 and #2 are IDENTICAL -> #2 is a cache HIT. #3 is UNIQUE -> a MISS. */}
      <Icon x={20} y={20} d={CHEVRON_DOWN} />
      <Icon x={260} y={20} d={CHEVRON_DOWN} />
      <Icon x={500} y={20} d={CHEVRON_UP} />
    </View>
  );
}

AppRegistry.registerComponent('EngSupersample', () => Fixture);
