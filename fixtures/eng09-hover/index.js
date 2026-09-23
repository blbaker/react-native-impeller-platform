/**
 * ENG-09 hover/cursor fixture — NOT a demo app.
 *
 * Proves the windowed hover tier end to end: GLFW cursor-position callback ->
 * screen->points conversion -> SceneGraph hit test -> retained hovered tag ->
 * pointerenter/leave through TouchEventEmitter, plus the cursor SHAPE resolved
 * from ViewProps.cursor.
 *
 * Layout is three NON-OVERLAPPING boxes at known coordinates so the gate can
 * hover a point and assert WHICH box answered and WHICH cursor it resolved:
 *   - hand: cursor:'pointer'  (the shape web/RN authors set for a control)
 *   - ibeam: cursor:'text'
 *   - arrow: no cursor prop (the default; every existing app is this)
 *
 * ⛔ THE CURSOR SIGNAL IS ViewProps.cursor, NOT "has a press handler".
 * Every <View> mounts a TouchEventEmitter whether or not onPress is wired, and
 * the emitter's enabled flag is private, so there is no "is hoverable" bit to
 * read. RN's own cursor prop is the honest source, and it is exactly what an
 * author sets. A Pressable does NOT set cursor:'pointer' by default, so the
 * hand box sets it explicitly here.
 */
import React from 'react';
import {AppRegistry, Pressable, Text, View} from 'react-native';

export const BOXES = [
  {id: 'hand', x: 0, y: 0, w: 400, h: 100, color: '#c0392b', cursor: 'pointer'},
  {id: 'ibeam', x: 0, y: 100, w: 400, h: 100, color: '#27ae60', cursor: 'text'},
  {id: 'arrow', x: 0, y: 200, w: 400, h: 100, color: '#2980b9'},
];

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      {BOXES.map(b => (
        <Pressable
          key={b.id}
          style={{
            position: 'absolute',
            left: b.x,
            top: b.y,
            width: b.w,
            height: b.h,
            backgroundColor: b.color,
            // ViewProps.cursor: undefined for the arrow box, which reads as
            // Cursor::Auto -> arrow, matching an un-annotated view.
            cursor: b.cursor,
          }}>
          {/* ⛔ A FULL-BLEED CHILD THAT IS ITS OWN NODE AND CARRIES NO CURSOR —
              THIS IS WHAT MAKES THE GATE ABLE TO FAIL. The Pressable carries
              cursor:'pointer'/'text', but hitTest returns the TOPMOST node
              under the point. This inner View covers the whole box, so the hit
              LEAF is a cursor:auto (arrow) node — exactly as a real button's
              inner label/icon is. Leaf-only resolution reads arrow for the hand
              and ibeam boxes and the gate FAILS; only walking up to the
              Pressable resolves the author's shape.

              collapsable={false} is LOAD-BEARING: Fabric flattens a <View> with
              no paint and no handlers into its parent, so a bare inner View
              vanishes as a node and the point lands on the Pressable again —
              which silently hides the leaf-only bug. A backgroundColor would
              also defeat flattening, but it would repaint the box; a
              transparent, explicitly non-collapsable View is the minimal thing
              that survives as a distinct hit leaf without changing a pixel. */}
          <View
            collapsable={false}
            style={{
              position: 'absolute',
              left: 0,
              top: 0,
              width: b.w,
              height: b.h,
              // No cursor prop -> Cursor::Auto -> the walk must inherit from
              // the Pressable above. Setting one here would defeat the test.
            }}>
            <Text style={{color: '#ffffff', fontSize: 16}}>{b.id}</Text>
          </View>
        </Pressable>
      ))}
    </View>
  );
}

AppRegistry.registerComponent('ENG09Hover', () => Fixture);
