/**
 * ENG-05 acceptance probe — the peer's own two arms, verbatim.
 *
 * ARM A: a 16x16 <Svg> with viewBox="0 0 24 24" and ONE diagonal path.
 *        The path spans the FULL 24-unit viewBox. If viewBox is honoured it
 *        must be squeezed into 16x16. If it is ignored the geometry paints in
 *        raw user units and runs to 24 — 8pt of overflow.
 *
 * ARM B: the SAME 16x16 box with viewBox="0 0 48 48". Correct scaling halves
 *        it again: the diagonal must terminate at 8x8, not 16x16 and not 48.
 *
 * Two arms because ONE arm cannot discriminate. A renderer that ignores
 * viewBox entirely and one that hardcodes a single scale both pass arm A.
 * Only the RATIO between A and B proves width/vbWidth is actually computed.
 *
 * Each Svg sits at a known offset inside a white 400x300 View so the probe can
 * address raw device pixels without guessing at layout.
 *
 * Anti-aliasing is measured on the SAME diagonals: a 45-degree edge with AA on
 * produces intermediate coverage values; with AA off every pixel is either
 * pure ink or pure background. That is a distribution test, not a spot test.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Path} from 'react-native-svg';

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      {/* ARM A — 16x16 box, 24-unit viewBox. Diagonal spans 0,0 -> 24,24. */}
      <View style={{position: 'absolute', left: 40, top: 40}}>
        <Svg width={16} height={16} viewBox="0 0 24 24">
          <Path d="M0 0 L24 24" stroke="#000000" strokeWidth={2} fill="none" />
        </Svg>
      </View>

      {/* ARM B — 16x16 box, 48-unit viewBox. Same diagonal, spans 0,0 -> 48,48.
          Honoured => 16/48 = 1/3 scale => ink stops at 16pt still, but the
          FIRST 8 units land in the first ~2.7pt. The discriminating measure is
          arm A's ink extent vs arm B's: A must reach further per user-unit. */}
      <View style={{position: 'absolute', left: 200, top: 40}}>
        <Svg width={16} height={16} viewBox="0 0 48 48">
          <Path d="M0 0 L24 24" stroke="#000000" strokeWidth={2} fill="none" />
        </Svg>
      </View>

      {/* CONTROL — an Svg whose viewBox EQUALS its box. Scaling is the identity
          here, so this arm must paint correctly on the current binary too. If
          it does not, the defect is not viewBox at all and both arms above are
          uninterpretable. */}
      <View style={{position: 'absolute', left: 40, top: 150}}>
        <Svg width={48} height={48} viewBox="0 0 48 48">
          <Path d="M0 0 L48 48" stroke="#000000" strokeWidth={2} fill="none" />
        </Svg>
      </View>

      {/* ARM C — NON-SQUARE BOX, square viewBox. 32x16 over 0 0 24 24.
          ⛔ THE ONLY ARM THAT DISCRIMINATES UNIFORM SCALE FROM PER-AXIS STRETCH.
          Arms A, B and CONTROL are all square-over-square, so w/vbW == h/vbH
          and a per-axis stretch is arithmetically identical to the correct
          uniform fit. Every one of them passes both implementations.

          Correct (xMidYMid meet, the SVG default when preserveAspectRatio is
          unset): scale = min(32/24, 16/24) = 0.667, so the 24-unit drawing
          paints 16x16 -- SQUARE -- and the 16pt of horizontal slack is split,
          centring it at x=8..24.
          Wrong (per-axis): 32/24 by 16/24 paints a 32x16 SHEARED diagonal
          filling the whole box, extent 32x16 and no left margin.

          The measurement is therefore the ASPECT of the ink and the presence of
          a left margin, not merely "did it paint". */}
      <View style={{position: 'absolute', left: 200, top: 150}}>
        <Svg width={32} height={16} viewBox="0 0 24 24">
          <Path d="M0 0 L24 24" stroke="#000000" strokeWidth={2} fill="none" />
        </Svg>
      </View>
    </View>
  );
}

AppRegistry.registerComponent('Eng05', () => Fixture);
