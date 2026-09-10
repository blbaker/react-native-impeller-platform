/**
 * ENG-05 follow-up: is the missing anti-aliasing STROKE-specific, or does it
 * affect FILL too?
 *
 * The peer's row blames the stroke draw call at SceneGraph.cpp:929 and asks for
 * "path fill and stroke paints get anti-aliasing on". Those are two different
 * claims and they imply different fixes, so measure them separately.
 *
 * A circle is the discriminating shape: every pixel on its edge is a partial
 * coverage sample if AA is on, at EVERY angle — unlike an axis-aligned box,
 * whose edges land exactly on pixel boundaries and legitimately show none.
 *
 *   1. FILLED circle,  no stroke  -> edge coverage attributable to FILL only
 *   2. STROKED circle, fill=none  -> edge coverage attributable to STROKE only
 *
 * If both read 0% partial, AA is off globally and the fix is not in the stroke
 * paint. If only 2 reads 0%, the peer's line citation is right.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Circle} from 'react-native-svg';

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      <Svg width={400} height={300} viewBox="0 0 400 300">
        {/* 1. FILL ONLY — a black disc. Its rim is the fill's AA. */}
        <Circle cx={100} cy={100} r={60} fill="#000000" />

        {/* 2. STROKE ONLY — a black ring. Both rims are the stroke's AA. */}
        <Circle cx={280} cy={100} r={60} fill="none" stroke="#000000" strokeWidth={6} />
      </Svg>
    </View>
  );
}

AppRegistry.registerComponent('Eng05AA', () => Fixture);
