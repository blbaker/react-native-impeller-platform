/**
 * FP-11: frame scheduling and vsync.
 *
 *   VsyncSpin    a red box sliding back and forth forever (Animated.loop,
 *                useNativeDriver: true). Every frame is requested by the
 *                NativeAnimated tick, so presents must land one per vsync.
 *   VsyncIdle    a static scene that never changes: zero presents once settled.
 *   VsyncMutate  a static scene that changes one box's colour once, 1 s after
 *                mount. Nothing else ever changes: the window must present no
 *                frames while idle, then one frame for the mutation.
 */
const React = require('react');
const { AppRegistry, View, Animated, Easing } = require('react-native');

const SCREEN = { flex: 1, backgroundColor: '#000' };
const BOX = { position: 'absolute', left: 0, top: 130, width: 40, height: 40 };

function VsyncSpin() {
  const v = React.useRef(new Animated.Value(0)).current;
  React.useEffect(() => {
    const anim = Animated.loop(
      Animated.sequence([
        Animated.timing(v, { toValue: 320, duration: 1000, easing: Easing.linear, useNativeDriver: true }),
        Animated.timing(v, { toValue: 0, duration: 1000, easing: Easing.linear, useNativeDriver: true }),
      ]),
    );
    anim.start();
    return () => anim.stop();
  }, [v]);
  return React.createElement(
    View,
    { style: SCREEN },
    React.createElement(Animated.View, {
      style: [BOX, { backgroundColor: '#f00', transform: [{ translateX: v }] }],
    }),
  );
}

function VsyncMutate() {
  const [on, setOn] = React.useState(false);
  React.useEffect(() => {
    const t = setTimeout(() => setOn(true), 1000);
    return () => clearTimeout(t);
  }, []);
  return React.createElement(
    View,
    { style: SCREEN },
    React.createElement(View, { style: [BOX, { backgroundColor: on ? '#0f0' : '#00f' }] }),
  );
}

function VsyncIdle() {
  return React.createElement(
    View,
    { style: SCREEN },
    React.createElement(View, { style: [BOX, { backgroundColor: '#00f' }] }),
  );
}

AppRegistry.registerComponent('VsyncSpin', () => VsyncSpin);
AppRegistry.registerComponent('VsyncIdle', () => VsyncIdle);
AppRegistry.registerComponent('VsyncMutate', () => VsyncMutate);
