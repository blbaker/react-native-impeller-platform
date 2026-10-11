/**
 * parity item 9 fixture: hit testing honours pointerEvents and transforms.
 *
 *   A  y 10..60:  Pressable PA (onPress -> 'PRESS A') under a full-width
 *      overlay View pointerEvents="none" (drawn on top). A click must reach PA.
 *   B  y 70..120: Pressable PB under an overlay Pressable BOX with
 *      pointerEvents="box-none" that holds its own child Pressable PBC at the
 *      right (x 300..380). A click on PB's area reaches PB, never BOX (the
 *      overlay itself is transparent to clicks); a click on PBC reaches PBC.
 *   C  y 130..180: View pointerEvents="box-only" (onPress on a Pressable
 *      wrapper is not allowed inside, so it is a Pressable PC_OUTER with
 *      pointerEvents box-only holding an inner Pressable PC_INNER). A click on
 *      the inner area reaches PC_OUTER, never PC_INNER.
 *   D  y 190..240: Pressable PD (60x50) at left 20 with transform
 *      translateX: 200 (painted at x 220..280). A click at its PAINTED spot
 *      (250, 215) must fire 'PRESS D'; a click at its untransformed spot
 *      (50, 215) must not.
 *   E  y 250..290: Pressable PE (60x40) at left 160, scale 0 -> unhittable.
 */
import React from 'react';
import {AppRegistry, Pressable, View} from 'react-native';

function P({name, style, children, pointerEvents}) {
  return (
    <Pressable
      onPress={() => console.log('PRESS ' + name)}
      pointerEvents={pointerEvents}
      style={style}>
      {children}
    </Pressable>
  );
}

const abs = (left, top, width, height, extra) => ({
  position: 'absolute', left, top, width, height, ...extra,
});

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      <P name="A" style={abs(20, 10, 200, 50, {backgroundColor: '#335577'})} />
      <View pointerEvents="none" style={abs(0, 0, 400, 65, {backgroundColor: 'rgba(255,255,255,0.1)'})} />

      <P name="B" style={abs(20, 70, 200, 50, {backgroundColor: '#335577'})} />
      {/* The box-none overlay is itself a Pressable (BOX), so a click that
          the overlay wrongly swallows shows up as PRESS BOX instead of B. */}
      <P name="BOX" pointerEvents="box-none" style={abs(0, 65, 400, 60)}>
        <P name="BC" style={abs(300, 5, 80, 50, {backgroundColor: '#775533'})} />
      </P>

      <P
        name="C_OUTER"
        pointerEvents="box-only"
        style={abs(20, 130, 200, 50, {backgroundColor: '#335577'})}>
        <P name="C_INNER" style={abs(50, 5, 100, 40, {backgroundColor: '#557733'})} />
      </P>

      <P
        name="D"
        style={abs(20, 190, 60, 50, {backgroundColor: '#773355', transform: [{translateX: 200}]})}
      />

      <P
        name="E"
        style={abs(160, 250, 60, 40, {backgroundColor: '#337755', transform: [{scale: 0}]})}
      />
    </View>
  );
}

AppRegistry.registerComponent('Item9HitTest', () => Fixture);
