/**
 * P9-F fixture — gradient fills via url(#id).
 *
 * ⛔ A GRADIENT FILL IS A REFERENCE, NOT A COLOUR.
 *
 * extractBrush() emits {type: 0, payload} for `fill="#ff0000"` but
 * {type: 1, brushRef: "id"} for `fill="url(#id)"`. The <LinearGradient> is a
 * SEPARATE node living inside <Defs> — which is never painted — so the engine
 * has to build a registry of defs and resolve the reference at paint time.
 * Reading the shape's own props can never produce the colour.
 *
 * Probes:
 *   1. LINEAR   red -> blue, left to right. Asserts the two ENDS differ AND
 *               that the midpoint is between them: a renderer that ignored the
 *               stops but drew *something* (first stop as a flat fill) passes
 *               "did it paint" and fails this.
 *   2. RADIAL   white centre -> black edge. Asserts centre is much lighter
 *               than edge.
 *   3. MISSING  fill="url(#nope)" with no such def. Must paint NOTHING —
 *               guessing a colour would be a bug that looks like a design
 *               choice.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Defs, LinearGradient, RadialGradient, Rect, Stop} from 'react-native-svg';

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      <Svg width={400} height={300} viewBox="0 0 400 300">
        <Defs>
          {/* objectBoundingBox units: 0..1 across the referencing shape. */}
          <LinearGradient id="lin" x1="0" y1="0" x2="1" y2="0">
            <Stop offset="0" stopColor="#ff0000" />
            <Stop offset="1" stopColor="#0000ff" />
          </LinearGradient>
          <RadialGradient id="rad" cx="0.5" cy="0.5" rx="0.5" ry="0.5">
            <Stop offset="0" stopColor="#ffffff" />
            <Stop offset="1" stopColor="#000000" />
          </RadialGradient>
        </Defs>

        {/* 1. LINEAR, 200 wide so the ramp is easy to probe. */}
        <Rect x={20} y={20} width={200} height={80} fill="url(#lin)" />

        {/* 2. RADIAL. */}
        <Rect x={20} y={140} width={120} height={120} fill="url(#rad)" />

        {/* 3. DANGLING REFERENCE — no such def. Must stay background. */}
        <Rect x={260} y={140} width={100} height={100} fill="url(#nope)" />
      </Svg>
    </View>
  );
}

AppRegistry.registerComponent('P9Gradient', () => Fixture);
