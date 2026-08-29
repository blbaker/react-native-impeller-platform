/**
 * P9-C fixture — does <G transform> actually move its children?
 *
 * ⛔ THE BUG THIS EXISTS TO CATCH IS SILENT AND HAS ALREADY SHIPPED ONCE.
 *
 * On rn-skia-prototype, RNSVGGroupProps carries a `matrix` field that
 * the renderer never reads, so <G transform> is DROPPED. Nothing errors. The
 * art just renders at the wrong size/place -- it cost a long hunt there (a
 * 4.87x oversizing), and the macOS tester still carries a viewBox workaround
 * because of it.
 *
 * The probe has to be a POSITION comparison, not "did it paint": a renderer
 * that ignores the transform still paints a perfectly good square, just in the
 * wrong spot. So two identical squares, same size, same colour, drawn from the
 * SAME `d` string -- one inside a translated <G>, one not. Their positions
 * must differ by exactly the translation.
 *
 * A scale probe rides along because translate-only support is a real and
 * common half-implementation.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {G, Path} from 'react-native-svg';

// One 40x40 box at the origin, reused by every probe so nothing can differ
// because of geometry.
const BOX = 'M0 0 L40 0 L40 40 L0 40 Z';

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      <Svg width={400} height={300} viewBox="0 0 400 300">
        {/* CONTROL — no group transform. Lands at (10,10)-(50,50). */}
        <G transform="translate(10, 10)">
          <Path d={BOX} fill="#ff0000" />
        </G>

        {/* TRANSLATE — same box, shifted right by 100 and down by 60.
            Lands at (110,70)-(150,110) if the matrix is consumed;
            at (10,10) on top of nothing if it is dropped. */}
        <G transform="translate(110, 70)">
          <Path d={BOX} fill="#0000ff" />
        </G>

        {/* SCALE — same box at 2x, translated clear of the others.
            Lands at (200,150)-(280,230) when scale is honoured;
            40x40 instead of 80x80 if only translation is implemented. */}
        <G transform="translate(200, 150) scale(2)">
          <Path d={BOX} fill="#008000" />
        </G>

        {/* ⛔ ROTATE — the ONLY probe that can see a b/c transpose.
            translate() and uniform scale() have b=c=0, so swapping the two
            off-diagonal terms is a perfect no-op for every probe above. A
            transposed matrix rotates the WRONG WAY (equivalent to negating the
            angle), which lands this box in a mirrored position.

            30deg about the box's own top-left, then placed at (300,40).
            Asymmetric on purpose: a square rotated 45deg is symmetric enough
            that a mirrored result can share a bounding box, so this uses a
            NON-square 40x20 box and an angle that is not a multiple of 45. */}
        <G transform="translate(300, 40) rotate(30)">
          <Path d="M0 0 L40 0 L40 20 L0 20 Z" fill="#ff00ff" />
        </G>
      </Svg>
    </View>
  );
}

AppRegistry.registerComponent('P9GTransform', () => Fixture);
