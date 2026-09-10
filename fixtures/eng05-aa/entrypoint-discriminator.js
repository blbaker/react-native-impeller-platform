/**
 * ENG-05b DISCRIMINATOR — is the missing AA a SURFACE property or a DRAW-CALL
 * property?
 *
 * The surface-configuration lead (no multisample requested when the surface is
 * created) predicts that NOTHING anti-aliases, because a 1-sample framebuffer
 * cannot produce coverage for any draw call. The draw-call lead predicts that
 * AA depends on WHICH Impeller entry point painted the edge.
 *
 * Those two make OPPOSITE predictions, so paint the same curved edge through
 * two different Impeller entry points and compare:
 *
 *   1. RRECT  — a plain RN <View> with borderRadius. SceneGraph paints this
 *      with ImpellerDisplayListBuilderDrawRoundedRect.
 *   2. SVGARC — a react-native-svg <Circle>. SceneGraph paints this with
 *      ImpellerDisplayListBuilderDrawPath.
 *
 * Both have curved edges that MUST sample partial coverage if AA is on.
 *
 *   both 0%      -> surface-level. GLFW_SAMPLES / EGL config is the lever.
 *   RRECT only   -> DrawPath-specific. The surface is fine and GLFW_SAMPLES
 *                   would be a no-op fix aimed at the wrong layer.
 *
 * Regions stay left of x=200pt so they remain ON CANVAS at 2x (--scale scales
 * content into the same framebuffer, it does not enlarge it).
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Circle} from 'react-native-svg';

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      {/* 1. RRECT — DrawRoundedRect path. Corners are the curved edge. */}
      <View
        style={{
          position: 'absolute',
          left: 30,
          top: 30,
          width: 140,
          height: 100,
          borderRadius: 50,
          backgroundColor: '#000000',
        }}
      />

      {/* 2. SVGARC — DrawPath. Same colour, same background, curved edge. */}
      <View style={{position: 'absolute', left: 0, top: 160}}>
        <Svg width={200} height={140} viewBox="0 0 200 140">
          <Circle cx={100} cy={70} r={55} fill="#000000" />
        </Svg>
      </View>
    </View>
  );
}

AppRegistry.registerComponent('Eng05AA', () => Fixture);
