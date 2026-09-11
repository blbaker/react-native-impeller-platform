/**
 * ENG-06's engine probe, standalone: does an Animated value move between
 * frames in a headless run?
 *
 * Authored by the macOS peer (internal request) as the
 * acceptance fixture for ENG-06, and kept here VERBATIM in behaviour so both
 * trees grade the same artifact. Its INVERTED sibling on the HostApp side
 * (tools/animated-probe.py) exits 0 when the defect reproduces.
 *
 * One screen, two boxes, both saturated green on black so a pixel count is
 * unambiguous:
 *
 *   A  a plain View at opacity 1        control, must paint
 *      100 x 100 = 10000 marked pixels on every frame
 *   B  an Animated.View whose opacity loops 0 -> 1   the subject: its
 *      marked count must DIFFER between the first frame and a later one
 *
 * The probe captures the first frame (--screenshot-first) and a later frame
 * (--screenshot) from the same run. B's count changing between them means the
 * engine drove the animation; identical means it did not.
 *
 * useNativeDriver is true on purpose: that is the path ENG-06 asks for. When
 * the module is absent RN throws on this flag, and that throw is itself a
 * measurement (B never paints at all -- in fact Fabric tears the whole tree
 * down and the frame is one black RootView).
 */
const React = require('react');
const { AppRegistry, View, Animated } = require('react-native');

const MARK = 'rgb(0, 255, 0)';
const BLOCK = { width: 100, height: 100, backgroundColor: MARK };
const ROW = { flexDirection: 'row', gap: 20, padding: 20 };

function Probe() {
  const v = React.useRef(new Animated.Value(0)).current;
  React.useEffect(() => {
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(v, { toValue: 1, duration: 500, useNativeDriver: true }),
        Animated.timing(v, { toValue: 0, duration: 500, useNativeDriver: true }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, [v]);

  return React.createElement(
    View,
    { style: { flex: 1, backgroundColor: 'rgb(0, 0, 0)' } },
    React.createElement(
      View,
      { style: ROW },
      /* A: the control. */
      React.createElement(View, { style: BLOCK }),
      /* B: the subject. */
      React.createElement(Animated.View, { style: [BLOCK, { opacity: v }] }),
    ),
  );
}

AppRegistry.registerComponent('probe', () => Probe);
