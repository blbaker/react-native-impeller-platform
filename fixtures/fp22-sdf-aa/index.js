/**
 * FP-22 SDF anti-aliasing fixture (tools/ci-sdf-aa.sh). 400x300 at scale 1, white background.
 * Geometry is fixed here and mirrored in tools/sdf_aa_gate.py (SHAPES):
 *   circle  View 80x80 at (20,20), borderRadius 40            -> DrawRoundedRect -> drawOval -> DrawCircle
 *   oval    View 140x80 at (120,20), borderRadius '50%'        -> elliptical radii -> drawOval
 *   rrect   View 120x80 at (20.5,130.5), borderRadius 20       -> DrawRoundedRect (circular corners)
 *   path    View 120x80 at (180,130), borderRadius 24 continuous -> DrawPath (never SDF: control)
 *   rect    View 60x40 at (320,20)                             -> DrawRect (integer edges)
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';

const abs = (left, top, width, height, extra) => ({position: 'absolute', left, top, width, height, ...extra});

function SdfAa() {
  return (
    <View style={{flex: 1, backgroundColor: '#ffffff'}}>
      <View style={abs(20, 20, 80, 80, {backgroundColor: '#d00000', borderRadius: 40})} />
      <View style={abs(120, 20, 140, 80, {backgroundColor: '#0000d0', borderRadius: '50%'})} />
      <View style={abs(20.5, 130.5, 120, 80, {backgroundColor: '#008000', borderRadius: 20})} />
      <View style={abs(180, 130, 120, 80, {backgroundColor: '#800080', borderRadius: 24, borderCurve: 'continuous'})} />
      <View style={abs(320, 20, 60, 40, {backgroundColor: '#000000'})} />
    </View>
  );
}

AppRegistry.registerComponent('Fp22SdfAa', () => SdfAa);
