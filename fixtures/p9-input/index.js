/**
 * P9 input fixture — NOT a demo app.
 *
 * Proves the whole input tier end to end: GLFW/host coordinates -> SceneGraph
 * hit test -> retained EventEmitter -> TouchEventEmitter -> RN Pressability ->
 * a JS onPress handler that actually runs.
 *
 * ⛔ THE PRESS MUST BE OBSERVABLE FROM OUTSIDE THE PROCESS.
 * A fixture that only flips React state proves nothing to a gate: the tree
 * would repaint identically whether or not the handler ran. Every handler here
 * calls Alert.alert(), because the host already counts alerts
 * (`alerts_shown=N`) as the canonical "JS reached native" signal. So a gate can
 * assert a press fired WITHOUT screenshot diffing.
 *
 * Layout is deliberately three NON-OVERLAPPING boxes at known coordinates, so
 * the gate can tap a point and assert WHICH box answered. A single fullscreen
 * button would pass even if the hit test ignored geometry entirely and returned
 * the first touchable it found.
 */
import React from 'react';
import {Alert, AppRegistry, Pressable, Text, View} from 'react-native';

// Points, matching what the gate taps. Kept in one place so the fixture and
// the gate cannot drift apart.
export const BOXES = [
  {id: 'top', x: 0, y: 0, w: 400, h: 100, color: '#c0392b'},
  {id: 'mid', x: 0, y: 100, w: 400, h: 100, color: '#27ae60'},
  {id: 'bot', x: 0, y: 200, w: 400, h: 100, color: '#2980b9'},
];

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      {BOXES.map(b => (
        <Pressable
          key={b.id}
          // Absolute so each box sits at exactly the coordinates the gate taps;
          // flex layout would make the gate's numbers depend on RN's spacing
          // rules rather than on the hit test being correct.
          style={{
            position: 'absolute',
            left: b.x,
            top: b.y,
            width: b.w,
            height: b.h,
            backgroundColor: b.color,
          }}
          onPress={() => Alert.alert('pressed', b.id)}>
          <Text style={{color: '#ffffff', fontSize: 16}}>{b.id}</Text>
        </Pressable>
      ))}
    </View>
  );
}

AppRegistry.registerComponent('P9Input', () => Fixture);
