/**
 * ENG-05b INSTRUMENT VALIDATION — not a defect probe.
 *
 * The AA probe reports "0 partial, 1 distinct luminance value" on both linux
 * and darwin. That is ALSO exactly what a probe would report if the readback,
 * the PPM writer, or the analyser's ink test could not represent intermediate
 * luminance AT ALL. Those two states are indistinguishable from the 0.0%
 * number alone, so the number cannot be trusted until the instrument is shown
 * to be capable of reading a partial value.
 *
 * So: paint two shapes whose intermediate pixels do NOT depend on
 * anti-aliasing.
 *
 *   1. HALF_ALPHA — a black disc at opacity 0.5 over white. Every INTERIOR
 *      pixel must blend to ~128. This is per-pixel alpha blending, not edge
 *      coverage: it is on whether AA is on or off.
 *   2. GRADIENT   — a black-to-white linear gradient rect. Must show many
 *      distinct luminance values across its span.
 *
 * If either reads back as pure-only, the 0.0% AA result is an artifact of the
 * instrument and ENG-05b's whole surface-configuration lead rests on nothing.
 * If both read back with the expected spread, the pipeline CAN carry partial
 * luminance end to end and the 0.0% on hard edges is a real engine property.
 *
 * Geometry note: regions are placed left of x=200pt so they stay ON CANVAS at
 * 2x, since --scale scales content into the same --width/--height framebuffer.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Circle, Rect, Defs, LinearGradient, Stop} from 'react-native-svg';

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      <Svg width={400} height={300} viewBox="0 0 400 300">
        <Defs>
          <LinearGradient id="g" x1="0" y1="0" x2="1" y2="0">
            <Stop offset="0" stopColor="#000000" />
            <Stop offset="1" stopColor="#ffffff" />
          </LinearGradient>
        </Defs>

        {/* 1. HALF_ALPHA — interior must blend to mid grey regardless of AA. */}
        <Circle cx={100} cy={100} r={60} fill="#000000" fillOpacity={0.5} />

        {/* 2. GRADIENT — must produce many distinct luminance values. */}
        <Rect x={30} y={200} width={140} height={60} fill="url(#g)" />
      </Svg>
    </View>
  );
}

AppRegistry.registerComponent('Eng05AA', () => Fixture);
