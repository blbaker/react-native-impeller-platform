/**
 * linux-arm64 touch fixture (Weston wl_touch) — NOT a demo app.
 *
 * Proves a REAL compositor touch reaches JS: Weston wl_touch -> the engine's
 * WaylandTouch listener -> GlfwSurface's mouse entry points -> hit test ->
 * Pressability / PanResponder -> a JS handler that runs.
 *
 * Every outcome is an Alert, because the host prints `alert=<title>` for each
 * one: a gate can tell WHICH box answered (not just that something did)
 * without diffing pixels.
 *
 * Layout: three non-overlapping tap boxes at fixed points, a drag strip, and
 * empty space below (the miss arm: a tap there must produce no alert).
 *   tap-a   x 0..200    y 0..100
 *   tap-b   x 200..400  y 0..100
 *   tap-c   x 400..600  y 0..100
 *   drag    x 0..600    y 150..250  (release after >= 150 pt right => drag-right)
 *   empty   y 300..400
 */
import React, {useRef} from 'react';
import {Alert, AppRegistry, PanResponder, Pressable, Text, View} from 'react-native';

export const TAPS = [
  {id: 'tap-a', x: 0, color: '#c0392b'},
  {id: 'tap-b', x: 200, color: '#27ae60'},
  {id: 'tap-c', x: 400, color: '#2980b9'},
];

function DragStrip() {
  const pan = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onMoveShouldSetPanResponder: () => true,
      onPanResponderRelease: (_e, g) => {
        Alert.alert(g.dx >= 150 ? 'drag-right' : `drag-short-${Math.round(g.dx)}`);
      },
    }),
  ).current;
  return (
    <View
      {...pan.panHandlers}
      style={{position: 'absolute', left: 0, top: 150, width: 600, height: 100, backgroundColor: '#8e44ad'}}>
      <Text style={{color: '#ffffff', fontSize: 16}}>drag</Text>
    </View>
  );
}

function Fixture() {
  return (
    <View style={{width: 600, height: 400, backgroundColor: '#111111'}}>
      {TAPS.map(b => (
        <Pressable
          key={b.id}
          style={{position: 'absolute', left: b.x, top: 0, width: 200, height: 100, backgroundColor: b.color}}
          onPress={() => Alert.alert(`pressed-${b.id}`)}>
          <Text style={{color: '#ffffff', fontSize: 16}}>{b.id}</Text>
        </Pressable>
      ))}
      <DragStrip />
    </View>
  );
}

AppRegistry.registerComponent('Arm64Touch', () => Fixture);
