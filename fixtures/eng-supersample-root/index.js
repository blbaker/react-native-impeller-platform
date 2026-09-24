/**
 * ENG item 2b fixture — ROOT SUPERSAMPLE (View border/corner AA).
 *
 * A single View with a large borderRadius and a 1px border, filled with a solid
 * colour on a contrasting background. The rounded corner's arc — both the fill's
 * curved edge against the background AND the 1px stroked border following it — is
 * a curve. If Impeller emits no edge-coverage AA for it, that arc is a BINARY
 * step (a pixel is fully the shape colour or fully background). Root supersample
 * renders the whole tree N x into an offscreen and downsamples once; the box
 * filter synthesises partial-coverage pixels along the arc.
 *
 * Colours are chosen so a partial pixel is unambiguous:
 *   background #ffffff (255), fill #303030 (48), border #000000 (0).
 * A partial-coverage pixel at the corner lands strictly between the fill/border
 * value and 255 — the gate counts that in-between band inside a small box around
 * the top-left corner arc.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      <View
        style={{
          position: 'absolute',
          left: 40,
          top: 40,
          width: 200,
          height: 200,
          backgroundColor: '#303030',
          borderColor: '#000000',
          borderWidth: 1,
          borderRadius: 60,
        }}
      />
    </View>
  );
}

AppRegistry.registerComponent('EngSupersampleRoot', () => Fixture);
