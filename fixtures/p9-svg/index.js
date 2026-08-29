/**
 * P9-B2 SVG fixture — NOT a demo app.
 *
 * Three probes, chosen so each one FAILS DIFFERENTLY:
 *
 *   1. SOLID    a filled path at full opacity -> must paint pixels.
 *   2. INVISIBLE the same path at fillOpacity={0} -> must paint NOTHING.
 *   3. RAMP     two identical paths at DIFFERENT fillOpacity -> must produce
 *               two DIFFERENT colours.
 *
 * ⛔ WHY 3 IS THE ONE THAT MATTERS
 *
 * A renderer that ignores fillOpacity entirely still passes 1. A renderer that
 * treats fillOpacity as all-or-nothing still passes 1 and 2. Only comparing two
 * paths that differ ONLY in fillOpacity proves the alpha is applied PER PATH --
 * which is the actual product requirement: the HostApp signature mark is 17 paths
 * whose grey ramp IS the antialiasing.
 *
 * Same rule as the other fixtures: react + react-native + react-native-svg
 * only, geometry as literal numbers so the gate probes what React laid out.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Path} from 'react-native-svg';

// Axis-aligned squares via an explicit `d` string. A rect element would test a
// different component; this keeps the whole test on RNSVGPath.
const box = (x, y, w, h) => `M${x} ${y} L${x + w} ${y} L${x + w} ${y + h} L${x} ${y + h} Z`;

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      <Svg width={400} height={300} viewBox="0 0 400 300">
        {/* 1. SOLID — pure red, full opacity. */}
        <Path d={box(20, 20, 80, 80)} fill="#ff0000" />

        {/* 2. INVISIBLE — identical geometry, zero fill opacity. A renderer
            that drops fillOpacity paints a second red square here. */}
        <Path d={box(140, 20, 80, 80)} fill="#ff0000" fillOpacity={0} />

        {/* 3. RAMP — same colour, same size, two opacities. On white these
            must resolve to two DIFFERENT pinks. Equal values mean the alpha
            is not per-path. */}
        <Path d={box(20, 150, 80, 80)} fill="#0000ff" fillOpacity={0.25} />
        <Path d={box(140, 150, 80, 80)} fill="#0000ff" fillOpacity={0.75} />
      </Svg>
    </View>
  );
}

AppRegistry.registerComponent('P9Svg', () => Fixture);
