/**
 * D4 dimensions-crossing fixture — NOT a demo app.
 *
 * ⛔ THE ONE QUESTION: did JS FIND OUT that the window resized?
 *
 * Every other probe in this repo asserts native-side state — scene_nodes,
 * frame= boxes, painted_during, refresh_paints, tap_hit, screenshot hashes.
 * The Mac measured it (tools/boundary-audit.py): boundary-crossing 0/16. All
 * sixteen PASS on a build where native geometry is perfect and JS is never
 * told. The rail bug lived precisely there and had nowhere to be caught.
 *
 * WHY A COLUMN COUNT, AND NOT "the view is 700 wide"
 *
 * A width assertion is satisfiable by the NATIVE side alone: Fabric
 * re-constrains the root and the view is 700px whether or not a single line of
 * JS ran. It cannot discriminate the defect.
 *
 * A COLUMN COUNT can only change if JS re-rendered. The children are produced
 * by a JS .map() over a count computed from the width JS believes it has. No
 * native re-layout can add a child that React did not create. So the assertion
 * is satisfiable ONLY by a round trip: native → didUpdateDimensions →
 * useWindowDimensions → re-render → new children → new nodes.
 *
 * That is the one-bit reason the Mac gave for preferring the column-partition
 * form over rail-presence, and it is right.
 *
 * ⛔ useWindowDimensions IS LOAD-BEARING FOR A SECOND REASON.
 * RCTDeviceEventEmitter.js defines global.__rctDeviceEventEmitter inside a
 * Metro module factory, so the global EXISTS ONLY ONCE SOMETHING REQUIRES IT.
 * Measured 2026-09-09: D4 against fixtures/p9-usesym printed
 *   DEVEVENT: didUpdateDimensions DROPPED (__rctDeviceEventEmitter undefined)
 * — a true negative. That fixture never touches Dimensions, so nothing ever
 * pulled the module in and the emitter genuinely did not exist. Importing
 * Dimensions here is what makes the receiving end real.
 */
import React from 'react';
import {AppRegistry, View, useWindowDimensions, Dimensions} from 'react-native';

// Touch Dimensions at module scope too, so the emitter global is registered
// during bundle evaluation rather than on first render. The initial metrics
// publish happens before the first commit; if the module were only pulled in
// by the hook, an emit racing that first render would take the DROPPED path
// for a reason that has nothing to do with the engine.
const INITIAL = Dimensions.get('window');

const COL_W = 200;
const BAR = 40;

function App() {
  // The hook, not a one-shot Dimensions.get(). A .get() at mount reads the
  // right value and then NEVER UPDATES — which is exactly the passing-for-the-
  // wrong-reason shape this gate exists to reject.
  const {width, height} = useWindowDimensions();

  // Integer partition of the width JS believes it has. 400 -> 2, 700 -> 3.
  const cols = Math.max(1, Math.floor(width / COL_W));

  // One green bar per column, laid out by JS. A native resize cannot change
  // this number; only a re-render can.
  const bars = [];
  for (let i = 0; i < cols; i++) {
    bars.push(
      <View
        key={i}
        style={{
          position: 'absolute',
          left: i * COL_W + 10,
          top: 10,
          width: BAR,
          height: BAR,
          backgroundColor: '#00aa00',
        }}
      />,
    );
  }

  return (
    <View style={{flex: 1, backgroundColor: '#ffffff'}}>
      {bars}
      {/* POSITIVE CONTROL. Depends on nothing but React rendering. If this is
          absent the bundle never mounted, which is a different failure from
          "JS was not told about the resize" and must not be read as one. */}
      <View
        style={{
          position: 'absolute',
          left: 10,
          top: 100,
          width: BAR,
          height: BAR,
          backgroundColor: '#0066cc',
        }}
      />
    </View>
  );
}

AppRegistry.registerComponent('D4Dimensions', () => App);

// Printed on every render, so the gate can read the LAST line rather than
// inferring from pixels. Format is grepped by ci-d4-dimensions-crossing.sh.
// eslint-disable-next-line no-console
console.log(
  `D4_INITIAL w=${INITIAL.width} h=${INITIAL.height} scale=${INITIAL.scale}`,
);
