/**
 * FP-18: partial repaint. A complex static scene (300 bordered, rounded,
 * labelled tiles on an 800x600 window) with ONE native-driven box that slides
 * and spins over it, so each frame's damage is the box's old + new box.
 *
 *   PartialSpinner  the box loops forever (translateX 0..560..0, rotate
 *                   0..720deg per 2 s): the per-frame damage arm
 *   PartialFinite   the same motion once (1 s), then the box rests at x=560:
 *                   the final frame must equal a --partial-repaint off run
 *   PartialWide     a full-width band 360 px tall (60% of the height) pulses
 *                   its opacity: damage is 100% wide, 60% high -> partial
 *   PartialHuge     a 720x540 panel (90% x 90%) pulses: -> full ("ratio")
 */
const React = require('react');
const { AppRegistry, View, Text, Animated, Easing } = require('react-native');

const COLS = 20;
const ROWS = 15;
const PALETTE = ['#1b5e20', '#0d47a1', '#4a148c', '#b71c1c', '#e65100', '#006064', '#3e2723'];

function Grid() {
  const tiles = [];
  for (let r = 0; r < ROWS; r += 1) {
    for (let c = 0; c < COLS; c += 1) {
      const i = r * COLS + c;
      tiles.push(
        React.createElement(
          View,
          {
            key: i,
            style: {
              position: 'absolute',
              left: c * 40 + 2,
              top: r * 40 + 2,
              width: 36,
              height: 36,
              borderRadius: 6,
              borderWidth: 2,
              borderColor: '#cfd8dc',
              backgroundColor: PALETTE[i % PALETTE.length],
              alignItems: 'center',
              justifyContent: 'center',
            },
          },
          React.createElement(Text, { style: { color: '#ffffff', fontSize: 11 } }, String(i)),
        ),
      );
    }
  }
  return React.createElement(View, { style: { position: 'absolute', left: 0, top: 0, right: 0, bottom: 0 } }, tiles);
}

const SCREEN = { flex: 1, backgroundColor: '#101418' };

function useDrive(loop, duration) {
  const v = React.useRef(new Animated.Value(0)).current;
  React.useEffect(() => {
    const one = Animated.timing(v, {
      toValue: 1,
      duration,
      easing: Easing.linear,
      useNativeDriver: true,
    });
    const anim = loop ? Animated.loop(one) : one;
    anim.start();
    return () => anim.stop();
  }, [v]);
  return v;
}

function boxApp(loop) {
  return function Box() {
    const v = useDrive(loop, loop ? 2000 : 1000);
    // The loop ping-pongs so the box never jumps (a jump's damage is one rect
    // spanning both ends, as Flutter's single damage rect would be).
    const tx = loop
      ? v.interpolate({ inputRange: [0, 0.5, 1], outputRange: [0, 560, 0] })
      : v.interpolate({ inputRange: [0, 1], outputRange: [0, 560] });
    const rot = v.interpolate({ inputRange: [0, 1], outputRange: ['0deg', '720deg'] });
    return React.createElement(
      View,
      { style: SCREEN },
      React.createElement(Grid),
      React.createElement(Animated.View, {
        style: {
          position: 'absolute',
          left: 100,
          top: 282,
          width: 36,
          height: 36,
          borderRadius: 6,
          backgroundColor: '#ffab00',
          transform: [{ translateX: tx }, { rotate: rot }],
        },
      }),
    );
  };
}

function pulseApp(style) {
  return function Pulse() {
    const v = useDrive(true, 1000);
    const opacity = v.interpolate({ inputRange: [0, 0.5, 1], outputRange: [1, 0.3, 1] });
    return React.createElement(
      View,
      { style: SCREEN },
      React.createElement(Grid),
      React.createElement(Animated.View, {
        style: [{ position: 'absolute', backgroundColor: '#ffab00' }, style, { opacity }],
      }),
    );
  };
}

AppRegistry.registerComponent('PartialSpinner', () => boxApp(true));
AppRegistry.registerComponent('PartialFinite', () => boxApp(false));
AppRegistry.registerComponent('PartialWide', () => pulseApp({ left: 0, right: 0, top: 120, height: 360 }));
AppRegistry.registerComponent('PartialHuge', () => pulseApp({ left: 40, top: 30, width: 720, height: 540 }));
