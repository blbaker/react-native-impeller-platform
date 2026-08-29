/**
 * P9 repaint fixture — NOT a demo app.
 *
 * The single question this answers: does the windowed repaint loop draw a
 * SECOND, DIFFERENT frame?
 *
 * ⛔ WHY THIS FIXTURE HAS TO EXIST
 *
 * requestAnimationFrame already worked on this engine BEFORE any repaint loop
 * did — bridgeless TimerManager installs it as a host function. So JS ticks,
 * callbacks fire, setState commits through Fabric, and the engine paints
 * exactly one frame and exits. Every "is it animating?" check you would
 * naturally write — did the callback run, did state change, did a commit
 * happen — PASSES on a completely static renderer.
 *
 * The only assertion that can tell the difference is pixels: capture at frame 0
 * and again later, and require the bytes to differ.
 *
 * So this fixture moves a solid block on a plain background using rAF. No
 * gradients, no text, no borders — if the frames differ, the ONLY thing that
 * can have caused it is a genuine repaint of new content.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';

const SURFACE = {width: 400, height: 300, background: '#ffffff'};
const BLOCK = {size: 80, color: '#ff0000'};

function Repaint() {
  const [x, setX] = React.useState(0);

  React.useEffect(() => {
    let raf;
    // Step by a large, fixed amount per frame. A subtle 1px drift would be
    // indistinguishable from rasteriser noise; 24px moves the whole block clear
    // of where it was, so "differs" cannot be a rounding artefact.
    const tick = () => {
      setX(prev => (prev + 24) % (SURFACE.width - BLOCK.size));
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, []);

  return (
    <View
      style={{
        width: SURFACE.width,
        height: SURFACE.height,
        backgroundColor: SURFACE.background,
      }}>
      <View
        style={{
          position: 'absolute',
          left: x,
          top: 110,
          width: BLOCK.size,
          height: BLOCK.size,
          backgroundColor: BLOCK.color,
        }}
      />
    </View>
  );
}

AppRegistry.registerComponent('P9Repaint', () => Repaint);
