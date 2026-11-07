/**
 * --window-hidden gate fixture (tools/ci-window-hidden.sh). Fixed positions,
 * so the same screen coordinates hit the same box at any window size.
 *   grey root;
 *   Pressable A red    (20,20)  100x80   -> PRESS A
 *   Pressable B green  (280,20) 100x80   -> PRESS B
 *   Pressable C blue   (20,180) 100x80   -> PRESS C
 *   ScrollView S at (140,20) 120x160, 12 rows of 40 -> SCROLL y=<offset>
 *   live-timer bar at (0,270) 10 px tall, width = 8 px per 50 ms tick
 *     (full 400 px after 50 ticks, ~2.5 s): only a running JS timer grows it.
 * Logs TICKS 20 ms=<wall ms for 20 ticks> once, so a throttled timer shows.
 */
const React = require('react');
const { AppRegistry, View, Pressable, ScrollView } = require('react-native');
const h = React.createElement;

const abs = (left, top, width, height, backgroundColor) =>
  ({ position: 'absolute', left, top, width, height, backgroundColor });

function App() {
  const [ticks, setTicks] = React.useState(0);
  React.useEffect(() => {
    const t0 = Date.now();
    let n = 0;
    const id = setInterval(() => {
      n += 1;
      if (n === 20) console.log('TICKS 20 ms=' + (Date.now() - t0));
      setTicks(n);
    }, 50);
    return () => clearInterval(id);
  }, []);
  const rows = [];
  for (let i = 0; i < 12; i++) {
    rows.push(h(View, { key: i, style: { height: 40, backgroundColor: i % 2 ? 'rgb(255,255,255)' : 'rgb(0,0,0)' } }));
  }
  return h(View, { style: { flex: 1, backgroundColor: 'rgb(128,128,128)' } },
    h(Pressable, { style: abs(20, 20, 100, 80, 'rgb(255,0,0)'), onPress: () => console.log('PRESS A') }),
    h(Pressable, { style: abs(280, 20, 100, 80, 'rgb(0,255,0)'), onPress: () => console.log('PRESS B') }),
    h(Pressable, { style: abs(20, 180, 100, 80, 'rgb(0,0,255)'), onPress: () => console.log('PRESS C') }),
    h(ScrollView, {
      style: abs(140, 20, 120, 160, 'rgb(64,64,64)'),
      scrollEventThrottle: 16,
      onScroll: (e) => console.log('SCROLL y=' + Math.round(e.nativeEvent.contentOffset.y)),
    }, rows),
    h(View, { style: abs(0, 270, Math.min(ticks * 8, 400), 10, 'rgb(255,255,0)') }));
}

AppRegistry.registerComponent('probe', () => App);
