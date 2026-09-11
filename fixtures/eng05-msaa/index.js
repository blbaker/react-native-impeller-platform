/**
 * ENG-05b MSAA gate fixture: the matched pair the peer asked for.
 *
 * The question is whether requesting a multisampled default framebuffer
 * (RNI_GLFW_SAMPLES=N -> GLFW_SAMPLES) changes anti-aliasing on the aliased
 * path route. Answering that needs BOTH halves, in ONE frame:
 *
 *   SUBJECT  a <Circle>, which SceneGraph stringifies to a `d` path and parses
 *            back into MoveTo/CubicCurveTo builder calls. Measured 0.0%
 *            partial coverage / 1 distinct luminance -- the aliased route. If
 *            MSAA does anything, THIS is where it shows up.
 *
 *   CONTROL  a horizontal gradient RAMP. It has nothing to do with AA: it is
 *            many distinct luminance values BY CONSTRUCTION.
 *
 * ⛔ WHY THE RAMP IS THE GATE, AND NOT DECORATION.
 * The expected result of this experiment is NO CHANGE. A gate whose only
 * assertion is "the subject did not change" passes identically when the engine
 * failed to start, when the screenshot is a blank frame, when the readback path
 * is broken, and when the probe measures the wrong region. Every one of those
 * reads as "MSAA changed nothing" and none of them is evidence of anything.
 *
 * The ramp is the instrument check riding in the same frame as the measurement:
 * it MUST report many distinct values. If it collapses to 1, the pipeline is
 * blind and the subject's 0.0% is meaningless rather than informative. This is
 * the same role probe-eng05-instrument.sh played for the original spike, moved
 * inline so it cannot drift out of sync with the thing it validates.
 *
 * Layout is fixed and the analyser slices by these coordinates:
 *   subject disc   centred (100,100) r=60   -> box  30,30 140x140
 *   control ramp   x 210..390, y 30..170    -> box 210,30 180x140
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Circle, Defs, LinearGradient, Rect, Stop} from 'react-native-svg';

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      <Svg width={400} height={300} viewBox="0 0 400 300">
        <Defs>
          <LinearGradient id="ramp" x1="0" y1="0" x2="1" y2="0">
            <Stop offset="0" stopColor="#000000" />
            <Stop offset="1" stopColor="#ffffff" />
          </LinearGradient>
        </Defs>

        {/* SUBJECT: the aliased route. A circle's edge samples every angle, so
            a single axis-aligned box cannot stand in for it -- a rect's edges
            legitimately land on pixel boundaries and show no partial coverage
            even with AA fully on. */}
        <Circle cx={100} cy={100} r={60} fill="#000000" />

        {/* CONTROL: many distinct values by construction, independent of AA. */}
        <Rect x={210} y={30} width={180} height={140} fill="url(#ramp)" />
      </Svg>
    </View>
  );
}

AppRegistry.registerComponent('Eng05Msaa', () => Fixture);
