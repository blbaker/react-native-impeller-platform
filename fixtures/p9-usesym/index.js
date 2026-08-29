/**
 * P9-G gate fixture — <Symbol> + <Use>: ONE asset, N mounting sites.
 *
 * ⛔ THE BUG THIS EXISTS TO CATCH IS NOT "PAINTS NOTHING".
 *
 * Before P9-G, Symbol and Use were unregistered. That did NOT make the asset
 * invisible: an unregistered component still mounts, and the <Path> children
 * inside the <Symbol> ARE registered, so the painter walked into them and drew
 * the definition once, at the defs block's own coordinates. Measured
 * 2026-08-28: green ink at the symbol's authoring position, nothing at the
 * <Use> sites. A stray mark in the wrong place, with a clean log -- which reads
 * as a layout/CSS bug and is not one.
 *
 * So the gate asserts BOTH halves, in one frame:
 *   - the definition site must be BARE   (no leak)
 *   - the use sites must have INK        (the reference resolved)
 * Either half alone passes for the wrong reason.
 *
 * ⚠️ SYMBOL CONTENT IS AUTHORED IN THE SYMBOL'S OWN viewBox COORDINATES.
 * A path drawn at the symbol's *page* position is outside its viewBox and the
 * <Use> transform then lands it somewhere unrelated -- which is how the first
 * cut of this fixture "failed" against a correct engine.
 *
 * Layout on a 400x300 white canvas, viewBox 0 0 400 300:
 *
 *   A (20,20) 80x80    control <Path>, RED. Must paint. Proves the run is sane.
 *   B (140,20) 80x80    where a LEAKED definition would land -- must stay bare.
 *                       (The <Defs> block is laid out at the origin, but the
 *                       symbol's viewBox-local geometry put the pre-fix leak
 *                       here; asserting the whole upper-right band is bare is
 *                       the cheap way to say "no stray ink".)
 *   C1 (20,150) 80x80   <Use> #1 -- GREEN, must paint.
 *   C2 (140,150) 80x80  <Use> #2 -- the SAME symbol, must ALSO paint.
 *   D  (300,250)        never touched. Negative control.
 *
 * ⚠️ TWO <Use> SITES, NOT ONE. A single instance passes even if the engine
 * paints the definition once at a coincidentally-right place. Two instances of
 * one definition can only both have ink if the reference is genuinely re-entered
 * per mounting site -- which is the entire claim being made.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Path, Defs, Symbol as SvgSymbol, Use} from 'react-native-svg';

const box = (x, y, w, h) =>
  `M${x} ${y} L${x + w} ${y} L${x + w} ${y + h} L${x} ${y + h} Z`;

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      <Svg width={400} height={300} viewBox="0 0 400 300">
        {/* A: control. Not a Use, not in a Defs. */}
        <Path d={box(20, 20, 80, 80)} fill="#ff0000" />

        {/* The definition. Its path fills the symbol's own 0..80 viewBox. */}
        <Defs>
          <SvgSymbol id="sym" viewBox="0 0 80 80">
            <Path d={box(0, 0, 80, 80)} fill="#00ff00" />
          </SvgSymbol>
        </Defs>

        {/* C1 and C2: the same symbol, two mounting sites. */}
        <Use href="#sym" x={20} y={150} width={80} height={80} />
        <Use href="#sym" x={140} y={150} width={80} height={80} />

        {/* C3: the SCALED instance. The symbol's viewBox is 0 0 80 80 and this
            mounts it at 40x40, so the engine must scale by 0.5. Without this
            site every <Use> in the fixture has a scale factor of exactly 1.0
            and dropping the viewBox->instance scale entirely is a NO-OP that
            the gate cannot see -- measured: that mutant survived.

            The probes are a matched pair and both are required:
              INSIDE  (275,175) must be green -- the instance painted
              OUTSIDE (320,220) must be bare  -- it did NOT paint at 80x80
            Scaled, the instance covers 260..300 x 160..200. UNSCALED it would
            cover 260..340 x 160..240, which is what (320,220) sits in.
            Inside-only passes for an unscaled instance (which covers the inside
            point too). Only the outside point proves the scale was applied. */}
        <Use href="#sym" x={260} y={160} width={40} height={40} />

        {/* A dangling reference. Must paint NOTHING and must not crash --
            url(#missing) is a real authoring state, not an error. */}
        <Use href="#no-such-symbol" x={300} y={20} width={80} height={80} />
      </Svg>
    </View>
  );
}

AppRegistry.registerComponent('P9UseSym', () => Fixture);
