/**
 * ENG-48 (the Mac's ENG-GRADIENT-ASK-1): does a second <Svg> of the same size
 * paint its OWN gradient, or the first one's picture?
 *
 * The Mac's fixture, verbatim for its five apps (pair, swap, alone-b, sized,
 * mirror), plus arms that each isolate ONE field of the resolved gradient, so
 * every field the per-<Svg> cache key holds has a fixture that sees it.
 *
 * Every app draws on white, inside one block at (20, 20). Each Svg is 64 x 100
 * and holds one Rect filled by a LinearGradient/RadialGradient. Slot P sits at
 * block x 0 (surface x 20..84), slot Q at block x 100 (surface x 120..184).
 *   A  red,  opacity 0 to 1 (clear left, red right)
 *   B  blue, opacity 1 to 0 (blue left, clear right)
 *   MA, MB  the same two, both green: the app's fade pair shape
 *
 *   pair     A then B                     the subject
 *   swap     B then A (same places)       which one keeps its own picture
 *   alone-b  B only                       B's true picture
 *   sized    A, then B one unit taller    a different size, a different key
 *   mirror   MA then MB                   the app's shape
 *
 * One-field arms (P, Q differ ONLY in the named field; refs render each alone):
 *   coords   A, then A with x1=1 x2=0           gradient coordinates
 *   units    A in userSpaceOnUse 0..64, then the same in objectBoundingBox
 *   offsets  A, then A with its first stop at 0.5
 *   kind     A (linear 0,0,1,0), then a radial with the same six numbers
 *   twins    A, then A's exact content under another id: MUST share (1 offscreen)
 *   sameid   two Svgs that each define id probe-s (red vs blue): ids are one
 *            document-wide map, so both MUST paint the same picture
 *   restop   one Svg, id probe-r: red-rising on frame 1, then (two rAFs later)
 *            blue-falling under the SAME id. Run with --frames 3.
 *
 * Reference apps (one Svg alone, so no second Svg can share its texture):
 *   ref-P-<x> / ref-Q-<x> for every x above.
 *
 * tools/ci-gradient-cache.sh renders each app headless and reads both slots.
 */
const React = require('react');
const { AppRegistry, View, Animated } = require('react-native');
const Svg = require('react-native-svg');

const e = React.createElement;
const { LinearGradient, RadialGradient, Stop, Rect } = Svg;
const SvgView = Svg.default || Svg.Svg;
const W = 64;
const H = 100;
const P_LEFT = 0;
const Q_LEFT = 100;

function stops(rgb, from, to, firstOffset) {
  return [
    e(Stop, { key: 's0', offset: firstOffset || '0', stopColor: rgb, stopOpacity: from }),
    e(Stop, { key: 's1', offset: '1', stopColor: rgb, stopOpacity: to }),
  ];
}

function svg(key, left, height, gradient, id) {
  return e(SvgView, { key, width: W, height, style: { position: 'absolute', left, top: 0 } }, [
    gradient,
    e(Rect, { key: 'r', x: 0, y: 0, width: W, height, fill: 'url(#' + id + ')' }),
  ]);
}

// The Mac's fade(): its own LinearGradient (x1 0 -> x2 1) per Svg.
function fade(key, id, rgb, from, to, left, height) {
  const h = height || H;
  return svg(key, left, h,
    e(LinearGradient, { key: 'g', id, x1: '0', y1: '0', x2: '1', y2: '0' }, stops(rgb, from, to)), id);
}

const RED = 'rgb(255,0,0)';
const BLUE = 'rgb(0,0,255)';
const GREEN = 'rgb(0,128,0)';

const A = (height, left) => fade('A', 'probe-a', RED, 0, 1, left === undefined ? P_LEFT : left, height || H);
const B = (height, left) => fade('B', 'probe-b', BLUE, 1, 0, left === undefined ? Q_LEFT : left, height || H);
const MA = (left) => fade('A', 'probe-ma', GREEN, 0, 1, left === undefined ? P_LEFT : left, H);
const MB = (left) => fade('B', 'probe-mb', GREEN, 1, 0, left === undefined ? Q_LEFT : left, H);

// coords: same stops, the ramp reversed.
const AR = (left) => svg('B', left, H,
  e(LinearGradient, { key: 'g', id: 'probe-ar', x1: '1', y1: '0', x2: '0', y2: '0' }, stops(RED, 0, 1)), 'probe-ar');
// units: identical numbers, user space vs bounding box.
const AU = (left) => svg('A', left, H,
  e(LinearGradient, { key: 'g', id: 'probe-au', x1: '0', y1: '0', x2: '64', y2: '0', gradientUnits: 'userSpaceOnUse' },
    stops(RED, 0, 1)), 'probe-au');
const AB = (left) => svg('B', left, H,
  e(LinearGradient, { key: 'g', id: 'probe-ab', x1: '0', y1: '0', x2: '64', y2: '0', gradientUnits: 'objectBoundingBox' },
    stops(RED, 0, 1)), 'probe-ab');
// offsets: the first stop moved to 0.5.
const AO = (left) => svg('B', left, H,
  e(LinearGradient, { key: 'g', id: 'probe-ao', x1: '0', y1: '0', x2: '1', y2: '0' }, stops(RED, 0, 1, '0.5')),
  'probe-ao');
// kind: a radial whose six numbers (fx,fy,rx,ry,cx,cy) equal A's linear
// (x1,y1,x2,y2 + the two unused slots) = 0,0,1,0,0,0.
const AK = (left) => svg('B', left, H,
  e(RadialGradient, { key: 'g', id: 'probe-ak', fx: '0', fy: '0', rx: '1', ry: '0', cx: '0', cy: '0' },
    stops(RED, 0, 1)), 'probe-ak');
// twins: A's exact content under another id.
const AT = (left) => fade('B', 'probe-at', RED, 0, 1, left, H);
// sameid: two Svgs that each define probe-s.
const S1 = (left) => fade('A', 'probe-s', RED, 0, 1, left, H);
const S2 = (left) => fade('B', 'probe-s', BLUE, 1, 0, left, H);

function block(children) {
  return function Probe() {
    return e(
      View,
      { style: { flex: 1, backgroundColor: 'rgb(255,255,255)' } },
      e(View, { style: { position: 'absolute', left: 20, top: 20, width: 200, height: 120 } }, children),
    );
  };
}

// restop: early frames paint red-rising, then the SAME id's stops change to
// blue-falling. The clock is a native-driven Animated.timing: headless steps it
// 16.667 ms per --frames frame, and its end callback (drained by the next
// frame's idle wait) flips the stops. JS timers and rAF cannot do this:
// headless boot drains them before the first frame, so they switch before
// anything paints. With 50 ms the switch lands about frame 4, so frame 1
// really paints (and caches) the red picture first.
function Restop() {
  const [late, setLate] = React.useState(false);
  const clock = React.useRef(new Animated.Value(0)).current;
  React.useEffect(() => {
    Animated.timing(clock, { toValue: 1, duration: 50, useNativeDriver: true, isInteraction: false })
      .start(({ finished }) => {
        console.log('ENG48_RESTOP switch finished=' + finished);
        setLate(true);
      });
  }, [clock]);
  const g = late
    ? e(LinearGradient, { key: 'g', id: 'probe-r', x1: '0', y1: '0', x2: '1', y2: '0' }, stops(BLUE, 1, 0))
    : e(LinearGradient, { key: 'g', id: 'probe-r', x1: '0', y1: '0', x2: '1', y2: '0' }, stops(RED, 0, 1));
  return e(
    View,
    { style: { flex: 1, backgroundColor: 'rgb(255,255,255)' } },
    e(View, { style: { position: 'absolute', left: 20, top: 20, width: 200, height: 120 } }, [
      svg('R', Q_LEFT, H, g, 'probe-r'),
      // The clock's view: 1 x 1, no background, outside both slots.
      e(Animated.View, { key: 'clock', style: { position: 'absolute', left: 0, top: 115, width: 1, height: 1, opacity: clock } }),
    ]),
  );
}

// The Mac's five apps.
AppRegistry.registerComponent('pair', () => block([A(), B()]));
AppRegistry.registerComponent('swap', () => block([B(), A()]));
AppRegistry.registerComponent('alone-b', () => block([B()]));
AppRegistry.registerComponent('sized', () => block([A(), B(H + 1)]));
AppRegistry.registerComponent('mirror', () => block([MA(), MB()]));

// One-field arms.
AppRegistry.registerComponent('coords', () => block([A(), AR(Q_LEFT)]));
AppRegistry.registerComponent('units', () => block([AU(P_LEFT), AB(Q_LEFT)]));
AppRegistry.registerComponent('offsets', () => block([A(), AO(Q_LEFT)]));
AppRegistry.registerComponent('kind', () => block([A(), AK(Q_LEFT)]));
AppRegistry.registerComponent('twins', () => block([A(), AT(Q_LEFT)]));
AppRegistry.registerComponent('sameid', () => block([S1(P_LEFT), S2(Q_LEFT)]));
AppRegistry.registerComponent('restop', () => Restop);

// References: each Svg alone in its own slot.
AppRegistry.registerComponent('ref-P-a', () => block([A()]));
AppRegistry.registerComponent('ref-Q-b', () => block([B()]));
AppRegistry.registerComponent('ref-Q-b101', () => block([B(H + 1)]));
AppRegistry.registerComponent('ref-P-ma', () => block([MA()]));
AppRegistry.registerComponent('ref-Q-mb', () => block([MB()]));
AppRegistry.registerComponent('ref-Q-ar', () => block([AR(Q_LEFT)]));
AppRegistry.registerComponent('ref-P-au', () => block([AU(P_LEFT)]));
AppRegistry.registerComponent('ref-Q-ab', () => block([AB(Q_LEFT)]));
AppRegistry.registerComponent('ref-Q-ao', () => block([AO(Q_LEFT)]));
AppRegistry.registerComponent('ref-Q-ak', () => block([AK(Q_LEFT)]));
AppRegistry.registerComponent('ref-Q-a', () => block([A(H, Q_LEFT)]));
AppRegistry.registerComponent('ref-Q-bf', () => block([fade('R', 'probe-rb', BLUE, 1, 0, Q_LEFT, H)]));
