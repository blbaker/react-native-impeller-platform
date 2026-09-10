/**
 * ENG-02 scroll fixture — NOT a demo app.
 *
 * Proves the ScrollView tier end to end: a real GLFW scroll wheel event ->
 * GlfwSurface scroll callback -> FabricHost::dispatchScroll -> the retained
 * ScrollViewEventEmitter -> onScroll in JS, AND the painted content actually
 * moving.
 *
 * ⛔ TWO INDEPENDENT SIGNALS, ON PURPOSE.
 *
 *   1. onScroll fires in JS. Observable from outside the process because the
 *      handler calls Alert.alert(), which the host already counts as
 *      `alerts_shown=N`. This is the "JS was told" arm.
 *
 *   2. The FIRST PAINTED ROW CHANGES. Observable in a screenshot. This is the
 *      "pixels moved" arm.
 *
 * Either alone is a lie in a different direction. A renderer that scrolls its
 * content but never notifies JS passes (2) and fails (1); an engine that emits
 * a perfect onScroll while painting a frozen tree passes (1) and fails (2).
 * hostapp v5's list would be broken in both cases.
 *
 * ⛔ THE ROWS ARE SOLID, SATURATED, AND DISTINCT PER ROW.
 * The gate reads the colour of the top content row out of a PPM. Rows that
 * shared a colour, or were textured, would let a scroll of the WRONG distance
 * pass — the assertion is "which row is on top", not "did anything change".
 */
import React from 'react';
import {Alert, AppRegistry, ScrollView, Text, View} from 'react-native';

// Points. The window/surface is 400x300 and each row is 100 tall, so exactly
// three rows are visible at rest and the 4th+ are strictly below the fold.
// Kept here so the fixture and the gate cannot drift apart.
export const ROW_H = 100;
export const ROWS = [
  {id: 'r0', color: '#ff0000'},
  {id: 'r1', color: '#00ff00'},
  {id: 'r2', color: '#0000ff'},
  {id: 'r3', color: '#ffff00'},
  {id: 'r4', color: '#ff00ff'},
  {id: 'r5', color: '#00ffff'},
];

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      <ScrollView
        style={{width: 400, height: 300}}
        // Fire on every delivered scroll, not once per 100ms. A throttled
        // emitter would make the gate's single wheel event racy.
        scrollEventThrottle={1}
        onScroll={e => {
          const y = e?.nativeEvent?.contentOffset?.y;
          Alert.alert('scrolled', String(y));
        }}>
        {ROWS.map(r => (
          <View
            key={r.id}
            style={{width: 400, height: ROW_H, backgroundColor: r.color}}>
            <Text style={{color: '#000000', fontSize: 16}}>{r.id}</Text>
          </View>
        ))}
      </ScrollView>
    </View>
  );
}

AppRegistry.registerComponent('P9Scroll', () => Fixture);
