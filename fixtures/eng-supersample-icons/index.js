/**
 * ENG item 2 fixture — PER-ICON SUPERSAMPLE POSITION (orientation + presence).
 *
 * FIVE up-arrow icons in a vertical column, each its own <Svg> root, so each is
 * a per-icon supersample subtree. This is the fixture the per-icon arm of
 * ci-supersample-position.sh drives. Laid out to fit the 400x300 HEADLESS
 * default surface (main.cpp) — no --window-size needed, same as every other
 * headless gate.
 *
 * WHY THIS EXISTS (distinct from eng-supersample-root)
 *   The root fixture proves the WHOLE-TREE composite (paintTreeSupersampled,
 *   N>=2) is upright. It cannot see the PER-ICON composite
 *   (paintSvgRootSupersampled), because at N>=2 the root path pre-empts the
 *   per-icon hook entirely. The per-icon hook runs at N==1 (and on backends
 *   where the root offscreen exceeds the GPU bound and falls through with
 *   supersample_ still set, e.g. the Mac at N=8). That hook once built and
 *   cached the offscreen texture and returned true WITHOUT compositing it — so
 *   paintNode skipped the in-place walk and every icon painted NOTHING while its
 *   background still drew, leaving a bare tile. This fixture makes that vanish a
 *   measured failure, at every N.
 *
 * ⛔ ABSOLUTE POSITIONING, ONE Svg PER WRAPPER. RN flexbox plus the <Svg> x/y
 * props double-offset and overlap; absolute left/top on a wrapping View pins
 * each icon to a known box the gate can address by arithmetic. Each wrapper is
 * 48x48 at a fixed top, 8px gap, five stacked from top=8 -> 288 inside the 300px
 * surface.
 *
 * ⛔ FILLED, STRONGLY ASYMMETRIC UP-ARROWS ON PURPOSE. A triangle apex-up has
 * FEW ink pixels in its top rows (near the apex) and MANY in its bottom rows
 * (the base). A vertically MIRRORED composite — the exact wrapped-FBO
 * bottom-left-origin bug — turns every up-arrow into a down-arrow, flipping that
 * top-vs-bottom ink balance. A symmetric glyph (a dot, a plus) could not tell an
 * upright composite from a flipped one; this one can. The path is a bare
 * triangle (apex at y=3, base at y=21) so the asymmetry is maximal.
 *
 * ⛔ FILL, NOT STROKE, HERE — the OPPOSITE of eng-supersample/index.js. That
 * fixture is the AA gate: it needs stroked tessellated edges because AA-vs-binary
 * is its measurement. THIS is the POSITION gate: it measures presence and
 * orientation, for which a solid filled body gives a large, stable ink mass and
 * an unambiguous top/bottom asymmetry. AA is not measured here.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Path} from 'react-native-svg';

// Apex at the TOP (y=3), base along the BOTTOM (y=21): an up-arrow. Filled.
const ARROW_UP = 'M12 3 L21 21 L3 21 Z';

// Five 48x48 wrappers, 8px gap: tops at 8, 64, 120, 176, 232.
const TOPS = [8, 64, 120, 176, 232];

function Arrow({top}) {
  return (
    <View style={{position: 'absolute', left: 40, top, width: 48, height: 48}}>
      <Svg width={48} height={48} viewBox="0 0 24 24">
        <Path d={ARROW_UP} fill="#808080" />
      </Svg>
    </View>
  );
}

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      {TOPS.map((top, i) => (
        <Arrow key={i} top={top} />
      ))}
    </View>
  );
}

AppRegistry.registerComponent('EngSupersampleIcons', () => Fixture);
