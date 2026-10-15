/**
 * FP-10: a native-driven Animated.timing must keep moving while JS is busy.
 *
 * A 40x40 red box slides translateX 0 -> 320 over 2666.7 ms, Easing.linear,
 * useNativeDriver: true. On the frame-counted clock that is exactly 2 px per
 * frame for 160 frames, so the gate maps the box's left edge (read back per
 * present with RNI_TEST_ANIM_ROW) onto the curve and gets lag in frames.
 *
 *   NativeSlideStall    the slide plus a requestAnimationFrame chain that
 *                       busy-loops 50 ms on every other callback
 *   NativeSlideControl  the slide with an idle JS thread (zero-stall control)
 *   NativeScrollEvent   Animated.event(onScroll, useNativeDriver: true) drives
 *                       the box's translateX from the ScrollView offset. RN
 *                       runs native event drivers only on its render thread,
 *                       so this arm proves scroll events still reach it.
 *
 * Every busy stall logs "jsstall n=<k>" so the gate can prove JS was blocked.
 */
const React = require('react');
const { AppRegistry, View, ScrollView, Animated, Easing } = require('react-native');

const SCREEN = { flex: 1, backgroundColor: '#000' };
const BOX = {
  position: 'absolute',
  left: 0,
  top: 130,
  width: 40,
  height: 40,
  backgroundColor: '#f00',
};

function useSlide() {
  const v = React.useRef(new Animated.Value(0)).current;
  React.useEffect(() => {
    const anim = Animated.timing(v, {
      toValue: 320,
      duration: 160 * (1000 / 60),
      easing: Easing.linear,
      useNativeDriver: true,
    });
    anim.start();
    return () => anim.stop();
  }, [v]);
  return v;
}

function useJsStall() {
  React.useEffect(() => {
    let alive = true;
    let odd = false;
    let n = 0;
    const step = () => {
      if (!alive) return;
      odd = !odd;
      if (odd) {
        const until = Date.now() + 50;
        while (Date.now() < until) {
          // busy: the JS thread is blocked for 50 ms
        }
        n += 1;
        console.log('jsstall n=' + n);
      }
      requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
    return () => {
      alive = false;
    };
  }, []);
}

function slideApp(stall) {
  return function Slide() {
    const tx = useSlide();
    if (stall) useJsStall();
    return React.createElement(
      View,
      { style: SCREEN },
      React.createElement(Animated.View, { style: [BOX, { transform: [{ translateX: tx }] }] }),
    );
  };
}

function ScrollEventApp() {
  const y = React.useRef(new Animated.Value(0)).current;
  const onScroll = Animated.event([{ nativeEvent: { contentOffset: { y } } }], {
    useNativeDriver: true,
  });
  const tx = y.interpolate({ inputRange: [0, 300], outputRange: [0, 300], extrapolate: 'clamp' });
  return React.createElement(
    View,
    { style: SCREEN },
    React.createElement(
      Animated.ScrollView,
      { style: { flex: 1 }, onScroll, scrollEventThrottle: 1 },
      React.createElement(View, { style: { height: 2000 } }),
    ),
    React.createElement(Animated.View, {
      pointerEvents: 'none',
      style: [BOX, { transform: [{ translateX: tx }] }],
    }),
  );
}

AppRegistry.registerComponent('NativeSlideStall', () => slideApp(true));
AppRegistry.registerComponent('NativeSlideControl', () => slideApp(false));
AppRegistry.registerComponent('NativeScrollEvent', () => ScrollEventApp);
