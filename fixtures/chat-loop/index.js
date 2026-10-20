/**
 * Chat-loop CPU fixture (Jim v5 report, 2026-10-19).
 *
 * A long chat transcript (300 <Text> paragraphs of ~200 chars in a ScrollView)
 * under a 3-dot typing indicator. Each dot is its own Animated.loop of an
 * Animated.sequence on opacity, period 1.2 s, exactly as Jim draws it.
 *
 *   ChatLoop         dots on the native driver (useNativeDriver: true)
 *   ChatLoopJs       the same dots on the JS driver (useNativeDriver: false):
 *                    one setNativeProps commit per dot per frame, the path
 *                    Jim's live sample showed
 *   ChatLoopControl  the transcript with no dots (must idle)
 *   ChatLoopMutate   every paragraph-shaping input changes once, then holds
 *                    (the cache's correctness arm: cached == uncached pixels)
 *
 * Logs "chatloop dots=<n> native=<0|1>" once the loops have started, so a gate
 * can tell which driver actually ran.
 */
const React = require('react');
const { AppRegistry, View, Text, ScrollView, Animated } = require('react-native');

const WORDS = (
  'the quick brown fox jumps over the lazy dog while a chat turn streams ' +
  'tokens into a long transcript and the typing indicator keeps pulsing ' +
  'above it so every paragraph below must stay laid out exactly once'
).split(' ');

function paragraph(i) {
  let s = 'Message ' + (i + 1) + ':';
  let k = i;
  while (s.length < 200) {
    s += ' ' + WORDS[k % WORDS.length];
    k += 7;
  }
  return s;
}
const PARAS = Array.from({ length: 300 }, (_, i) => paragraph(i));

const SCREEN = { flex: 1, backgroundColor: '#101114' };
const DOT = { width: 10, height: 10, borderRadius: 5, backgroundColor: '#e8e8ea', marginRight: 6 };
const TEXT = { color: '#d6d6da', fontSize: 14, lineHeight: 20, marginBottom: 8 };

function useDot(delayMs, native) {
  const v = React.useRef(new Animated.Value(0.3)).current;
  React.useEffect(() => {
    const loop = Animated.loop(
      Animated.sequence([
        Animated.delay(delayMs),
        Animated.timing(v, { toValue: 1, duration: 360, useNativeDriver: native }),
        Animated.timing(v, { toValue: 0.3, duration: 360, useNativeDriver: native }),
        Animated.timing(v, { toValue: 0.3, duration: 480 - delayMs, useNativeDriver: native }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, [v, delayMs, native]);
  return v;
}

function Dots({ native }) {
  const a = useDot(0, native);
  const b = useDot(120, native);
  const c = useDot(240, native);
  React.useEffect(() => {
    const t = setTimeout(() => {
      // __isNative is set by __makeNative when a native-driver animation starts.
      const isNative = a.__isNative === true && b.__isNative === true && c.__isNative === true;
      console.log('chatloop dots=3 native=' + (isNative ? 1 : 0));
    }, 500);
    return () => clearTimeout(t);
  }, [a, b, c]);
  return React.createElement(
    View,
    { style: { flexDirection: 'row', padding: 12 } },
    React.createElement(Animated.View, { style: [DOT, { opacity: a }] }),
    React.createElement(Animated.View, { style: [DOT, { opacity: b }] }),
    React.createElement(Animated.View, { style: [DOT, { opacity: c }] }),
  );
}

function chatApp(dots, native) {
  return function Chat() {
    React.useEffect(() => {
      if (!dots) console.log('chatloop dots=0 native=0');
    }, []);
    return React.createElement(
      View,
      { style: SCREEN },
      dots ? React.createElement(Dots, { native }) : null,
      React.createElement(
        ScrollView,
        { style: { flex: 1 }, contentContainerStyle: { padding: 12 } },
        PARAS.map((p, i) => React.createElement(Text, { key: i, style: TEXT }, p)),
      ),
    );
  };
}

// Every shaping input of a <Text> changes once, a step every 250 ms, then the
// screen holds still. A paragraph cache that kept any stale layout paints a
// different final frame than the uncached engine (RNI_PARAGRAPH_CACHE=0).
const STEP_WORDS = ['streaming', 'tokens', 'arrive', 'one', 'at', 'a', 'time'];
function MutateApp() {
  const [step, setStep] = React.useState(0);
  React.useEffect(() => {
    if (step >= 6) {
      console.log('chatloop mutate done step=' + step);
      return undefined;
    }
    const t = setTimeout(() => setStep(step + 1), 250);
    return () => clearTimeout(t);
  }, [step]);
  const T = (style, s) => React.createElement(Text, { style: [TEXT, style] }, s);
  return React.createElement(
    View,
    { style: [SCREEN, { padding: 12 }] },
    T(null, STEP_WORDS.slice(0, step + 1).join(' ')), // text content
    T({ color: step % 2 ? '#ff5555' : '#55ff55' }, 'this colour flips every step'), // run colour
    T({ opacity: step >= 3 ? 0.4 : 1 }, 'own opacity drops at step three'), // text alpha
    React.createElement(
      View,
      { style: { width: step >= 4 ? 170 : 380 } }, // layout width
      T(null, 'this paragraph re-wraps when its box narrows at step four of six'),
    ),
    T({ fontSize: step >= 5 ? 20 : 14 }, 'font size grows at step five'), // run size
    T({ textAlign: step >= 6 ? 'right' : 'left' }, 'aligned right at step six'), // node align
    PARAS.slice(0, 12).map((p, i) => React.createElement(Text, { key: i, style: TEXT }, p)),
  );
}

AppRegistry.registerComponent('ChatLoop', () => chatApp(true, true));
AppRegistry.registerComponent('ChatLoopJs', () => chatApp(true, false));
AppRegistry.registerComponent('ChatLoopControl', () => chatApp(false, false));
AppRegistry.registerComponent('ChatLoopMutate', () => MutateApp);
