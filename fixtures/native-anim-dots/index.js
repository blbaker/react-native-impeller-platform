/**
 * Native-driven typing dots (Jim v5 report, 2026-10-19 "native-animated").
 *
 * Jim's TypingDot, switched to useNativeDriver: true, rendered all three dots
 * parked at their rest value on darwin: the loop never reached the view.
 * This fixture isolates which part of that shape the engine drops.
 *
 * One row of three 40x40 white dots at (20,20), (80,20), (140,20) on #101114.
 *
 *   DotsOpacity     plain Animated.Value on opacity (the shape ci-animate covers)
 *   DotsInterp      opacity = value.interpolate(...)
 *   DotsTranslate   transform: [{ translateY: value.interpolate(...) }] only
 *   DotsJim         Jim's TypingDot exactly: interpolated opacity AND
 *                   translateY, loop(sequence([timing+delay, timing,
 *                   timing duration 0 + delay])), cycle 900 ms
 *   DotsJimJs       DotsJim on the JS driver (the working reference)
 *   DotsJimScroll   DotsJim inside a ScrollView bubble, as on Jim's chat screen
 *
 * Logs "nativedots app=<name> native=<0|1>" once the loops have started.
 */
const React = require('react');
const { AppRegistry, View, ScrollView, Animated } = require('react-native');

const CYCLE = 900;
const RISE = 12; // Jim rises 3 pt on a 6 pt dot; scaled to the 40 pt dot
const REST = 0.35;
const PEAK = 1;
const SCREEN = { flex: 1, backgroundColor: '#101114' };
const ROW = { flexDirection: 'row', paddingLeft: 20, paddingTop: 20 + RISE };
const DOT = { width: 40, height: 40, borderRadius: 4, backgroundColor: '#ffffff', marginRight: 20 };

function useJimLoop(v, index, native) {
  React.useEffect(() => {
    const up = CYCLE / 4;
    const delay = (index * CYCLE) / 6;
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(v, { toValue: 1, duration: up, delay, useNativeDriver: native }),
        Animated.timing(v, { toValue: 0, duration: up, useNativeDriver: native }),
        Animated.timing(v, { toValue: 0, duration: 0, delay: CYCLE - delay - 2 * up, useNativeDriver: native }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, [v, index, native]);
}

function makeDot(kind, native) {
  return function Dot({ index }) {
    const v = React.useRef(new Animated.Value(kind === 'opacity' ? REST : 0)).current;
    if (kind === 'opacity') {
      React.useEffect(() => {
        const loop = Animated.loop(
          Animated.sequence([
            Animated.delay(index * 150),
            Animated.timing(v, { toValue: PEAK, duration: 225, useNativeDriver: native }),
            Animated.timing(v, { toValue: REST, duration: 225, useNativeDriver: native }),
            Animated.timing(v, { toValue: REST, duration: 450 - index * 150, useNativeDriver: native }),
          ]),
        );
        loop.start();
        return () => loop.stop();
      }, [v, index]);
      return React.createElement(Animated.View, { style: [DOT, { opacity: v }] });
    }
    useJimLoop(v, index, native);
    const opacity = v.interpolate({ inputRange: [0, 1], outputRange: [REST, PEAK] });
    const translateY = v.interpolate({ inputRange: [0, 1], outputRange: [0, -RISE] });
    const style =
      kind === 'interp' ? { opacity }
        : kind === 'translate' ? { transform: [{ translateY }] }
          : { opacity, transform: [{ translateY }] };
    return React.createElement(Animated.View, { style: [DOT, style] });
  };
}

function makeApp(name, kind, native, inScroll) {
  const Dot = makeDot(kind, native);
  return function App() {
    React.useEffect(() => {
      const t = setTimeout(() => console.log('nativedots app=' + name + ' native=' + (native ? 1 : 0)), 300);
      return () => clearTimeout(t);
    }, []);
    const row = React.createElement(
      View,
      { style: ROW },
      React.createElement(Dot, { index: 0 }),
      React.createElement(Dot, { index: 1 }),
      React.createElement(Dot, { index: 2 }),
    );
    if (!inScroll) return React.createElement(View, { style: SCREEN }, row);
    return React.createElement(
      View,
      { style: SCREEN },
      React.createElement(
        ScrollView,
        { style: { flex: 1 } },
        React.createElement(View, { style: { backgroundColor: '#101114' } }, row),
      ),
    );
  };
}

// requestAnimationFrame contract (rAF pacing, AnimationFrameScheduler.h).
// One frame's batch: A cancels B (same-batch cancel), a throwing callback must
// not stop C, D is cancelled before any flush, and a rAF registered INSIDE a
// callback runs on a LATER frame (later timestamp). Then a 2 s rAF loop
// measures the rate: paced, it is the frame rate (~60/s); RN's setTimeout(0)
// rAF runs thousands per second.
function RafSemanticsApp() {
  React.useEffect(() => {
    let ranA = false, ranB = false, ranC = false, ranD = false;
    let tsA = -1, tsNested = -1;
    let idB = 0;
    requestAnimationFrame((t) => {
      ranA = true; tsA = t;
      cancelAnimationFrame(idB);
      requestAnimationFrame((t2) => { tsNested = t2; startRate(); });
    });
    idB = requestAnimationFrame(() => { ranB = true; });
    requestAnimationFrame(() => { throw new Error('raf-semantics expected throw'); });
    requestAnimationFrame(() => { ranC = true; });
    const idD = requestAnimationFrame(() => { ranD = true; });
    cancelAnimationFrame(idD);
    function startRate() {
      console.log('rafsem a=' + (ranA ? 1 : 0) + ' b=' + (ranB ? 1 : 0) + ' c=' + (ranC ? 1 : 0) +
        ' d=' + (ranD ? 1 : 0) + ' nested_later=' + (tsNested > tsA ? 1 : 0));
      const t0 = Date.now();
      let n = 0;
      const step = () => {
        n += 1;
        if (Date.now() - t0 < 2000) requestAnimationFrame(step);
        else console.log('rafrate per_s=' + Math.round((n * 1000) / (Date.now() - t0)));
      };
      requestAnimationFrame(step);
    }
  }, []);
  return React.createElement(View, { style: SCREEN });
}

AppRegistry.registerComponent('RafSemantics', () => RafSemanticsApp);
AppRegistry.registerComponent('DotsOpacity', () => makeApp('DotsOpacity', 'opacity', true, false));
AppRegistry.registerComponent('DotsInterp', () => makeApp('DotsInterp', 'interp', true, false));
AppRegistry.registerComponent('DotsTranslate', () => makeApp('DotsTranslate', 'translate', true, false));
AppRegistry.registerComponent('DotsJim', () => makeApp('DotsJim', 'jim', true, false));
AppRegistry.registerComponent('DotsJimJs', () => makeApp('DotsJimJs', 'jim', false, false));
AppRegistry.registerComponent('DotsJimScroll', () => makeApp('DotsJimScroll', 'jim', true, true));
