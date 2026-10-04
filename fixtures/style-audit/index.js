/**
 * ENGINE STYLE AUDIT probe for react-native-impeller (rn-impeller, GLFW host).
 *
 * One labelled cell per feature, 240 x 150 points, five cells per row, on a
 * white page. Each cell has two slots at fixed positions:
 *   CONTROL slot at (cellX + 30,  cellY + 45)  same element WITHOUT the feature
 *   FEATURE slot at (cellX + 150, cellY + 45)  same element WITH the feature
 * measure.py reads the screenshot and compares the two slots per cell.
 *
 * Scenes (selected with --initial-url probe://<scene>):
 *   grid (default)  the style grid
 *   modal           a visible <Modal> (red box) followed by a full-screen blue sibling
 *   tap-boxnone     overlay with pointerEvents="box-none" over a Pressable
 *   tap-auto        same overlay with pointerEvents default (control)
 *   tap-hitslop     40x40 Pressable with hitSlop 20, tapped 10pt outside
 *   tap-noslop      same Pressable without hitSlop (control)
 *   sticky          ScrollView with stickyHeaderIndices [0] (windowed scroll run)
 *   sticky-control  same ScrollView without stickyHeaderIndices
 *   snap            ScrollView snapToInterval 60, one 40pt wheel notch (windowed)
 *   snap-control    same without snapToInterval
 *   hscroll         horizontal ScrollView, horizontal wheel (windowed)
 *   select          selectable Text, dragged across (headless --drag)
 *   select-control  same Text, no drag
 *   tap-pressin     Pressable whose onPressIn raises an alert (pressed-state path)
 * Cell order below is the contract measure.py reads (it parses the `id:` keys).
 */
const React = require('react');
const RN = require('react-native');
const {
  AppRegistry, View, Text, ScrollView, Image, ActivityIndicator, Switch,
  TextInput, Modal, StatusBar, Pressable, Alert, Linking,
} = RN;
const h = React.createElement;

const BLUE = 'rgb(0,0,255)';
const RED = 'rgb(255,0,0)';
const GREEN = 'rgb(0,255,0)';
const BLACK = 'rgb(0,0,0)';
const box = (extra) => h(View, { style: [{ width: 60, height: 60, backgroundColor: BLUE }, extra] });
const sq = (x, y, s, c, extra) =>
  h(View, { style: [{ position: 'absolute', left: x, top: y, width: s, height: s, backgroundColor: c }, extra] });
const txt = (s, style, props) => h(Text, Object.assign({ style: [{ fontSize: 20, color: BLACK }, style] }, props || {}), s);
const RED_PNG =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEUlEQVR4nGP8z4AATEhsPBwAM9EBBzDn4UwAAAAASUVORK5CYII=';

const TESTS = [
  // ---- shadows ----
  { id: 'shadowIOS', c: () => box(), f: () => box({ shadowColor: BLACK, shadowOffset: { width: 6, height: 6 }, shadowOpacity: 0.9, shadowRadius: 6 }) },
  { id: 'boxShadow', c: () => box(), f: () => box({ boxShadow: '6px 6px 6px 0px rgba(0,0,0,0.9)' }) },
  { id: 'boxShadowInset', c: () => box(), f: () => box({ boxShadow: 'inset 0px 0px 0px 10px rgb(255,0,0)' }) },
  { id: 'elevation', c: () => box(), f: () => box({ elevation: 12 }) },
  { id: 'textShadow', c: () => txt('Ab', { fontSize: 32, color: RED }), f: () => txt('Ab', { fontSize: 32, color: RED, textShadowColor: BLUE, textShadowOffset: { width: 4, height: 4 }, textShadowRadius: 1 }) },
  // ---- opacity / transform ----
  { id: 'opacityGroup',
    c: () => h(View, { style: { width: 60, height: 60 } }, sq(0, 0, 40, RED, { opacity: 0.5 }), sq(20, 20, 40, RED, { opacity: 0.5 })),
    f: () => h(View, { style: { width: 60, height: 60, opacity: 0.5 } }, sq(0, 0, 40, RED), sq(20, 20, 40, RED)) },
  { id: 'translate', c: () => box({ width: 40, height: 40 }), f: () => box({ width: 40, height: 40, transform: [{ translateX: 20 }, { translateY: 10 }] }) },
  { id: 'scale', c: () => box({ width: 40, height: 40 }), f: () => box({ width: 40, height: 40, transform: [{ scale: 0.5 }] }) },
  { id: 'rotate', c: () => box({ width: 40, height: 40 }), f: () => box({ width: 40, height: 40, transform: [{ rotate: '45deg' }] }) },
  { id: 'skewX', c: () => box({ width: 40, height: 40 }), f: () => box({ width: 40, height: 40, transform: [{ skewX: '30deg' }] }) },
  { id: 'transformOrigin', c: () => box({ width: 40, height: 40, transform: [{ scale: 0.5 }] }), f: () => box({ width: 40, height: 40, transformOrigin: 'top left', transform: [{ scale: 0.5 }] }) },
  { id: 'perspective', c: () => box({ transform: [{ rotateY: '50deg' }] }), f: () => box({ transform: [{ perspective: 120 }, { rotateY: '50deg' }] }) },
  { id: 'backfaceHidden', c: () => box({ transform: [{ rotateY: '180deg' }] }), f: () => box({ transform: [{ rotateY: '180deg' }], backfaceVisibility: 'hidden' }) },
  // ---- borders ----
  { id: 'radiusPerCorner', c: () => box(), f: () => box({ borderTopLeftRadius: 30 }) },
  { id: 'radiusPercent', c: () => box(), f: () => box({ borderRadius: '50%' }) },
  { id: 'borderDashed', c: () => box({ backgroundColor: 'white', borderWidth: 4, borderColor: BLACK }), f: () => box({ backgroundColor: 'white', borderWidth: 4, borderColor: BLACK, borderStyle: 'dashed' }) },
  { id: 'borderDotted', c: () => box({ backgroundColor: 'white', borderWidth: 4, borderColor: BLACK }), f: () => box({ backgroundColor: 'white', borderWidth: 4, borderColor: BLACK, borderStyle: 'dotted' }) },
  { id: 'borderPerSide', c: () => box({ backgroundColor: 'white', borderWidth: 4, borderColor: BLACK }),
    f: () => box({ backgroundColor: 'white', borderTopWidth: 10, borderTopColor: RED, borderLeftWidth: 4, borderLeftColor: GREEN, borderRightWidth: 0, borderBottomWidth: 2, borderBottomColor: BLUE }) },
  { id: 'roundedMixedBorder', c: () => box({ backgroundColor: 'white', borderRadius: 20, borderWidth: 4, borderColor: BLUE }),
    f: () => box({ backgroundColor: 'white', borderRadius: 20, borderWidth: 4, borderColor: BLUE, borderTopColor: RED }) },
  { id: 'overflowRounded',
    c: () => h(View, { style: { width: 60, height: 60, borderRadius: 30 } }, sq(0, 0, 60, RED)),
    f: () => h(View, { style: { width: 60, height: 60, borderRadius: 30, overflow: 'hidden' } }, sq(0, 0, 60, RED)) },
  { id: 'overflowRect',
    c: () => h(View, { style: { width: 60, height: 60 } }, sq(-15, -15, 90, RED)),
    f: () => h(View, { style: { width: 60, height: 60, overflow: 'hidden' } }, sq(-15, -15, 90, RED)) },
  { id: 'outline', c: () => box(), f: () => box({ outlineWidth: 4, outlineColor: RED, outlineStyle: 'solid', outlineOffset: 4 }) },
  // ---- backgrounds, filters, blending ----
  { id: 'gradientLinear', c: () => box({ backgroundColor: 'rgb(128,128,128)' }), f: () => box({ experimental_backgroundImage: 'linear-gradient(to right, rgb(255,0,0), rgb(0,0,255))' }) },
  { id: 'gradientRadial', c: () => box({ backgroundColor: 'rgb(128,128,128)' }), f: () => box({ backgroundColor: undefined, experimental_backgroundImage: 'radial-gradient(circle, rgb(255,0,0), rgb(0,0,255))' }) },
  { id: 'filterBlur', c: () => box(), f: () => box({ filter: 'blur(4px)' }) },
  { id: 'filterBrightness', c: () => box(), f: () => box({ filter: 'brightness(0.5)' }) },
  { id: 'filterGrayscale', c: () => box({ backgroundColor: RED }), f: () => box({ backgroundColor: RED, filter: 'grayscale(1)' }) },
  { id: 'filterDropShadow', c: () => box(), f: () => box({ filter: 'drop-shadow(6px 6px 4px rgb(0,0,0))' }) },
  { id: 'mixBlendMode',
    c: () => h(View, { style: { width: 60, height: 60, backgroundColor: GREEN } }, sq(10, 10, 40, RED)),
    f: () => h(View, { style: { width: 60, height: 60, backgroundColor: GREEN } }, sq(10, 10, 40, RED, { mixBlendMode: 'multiply' })) },
  { id: 'isolation',
    c: () => h(View, { style: { width: 60, height: 60, backgroundColor: GREEN } }, h(View, { style: { width: 60, height: 60 } }, sq(10, 10, 40, RED, { mixBlendMode: 'multiply' }))),
    f: () => h(View, { style: { width: 60, height: 60, backgroundColor: GREEN } }, h(View, { style: { width: 60, height: 60, isolation: 'isolate' } }, sq(10, 10, 40, RED, { mixBlendMode: 'multiply' }))) },
  // ---- stacking and layout ----
  { id: 'zIndex',
    c: () => h(View, { style: { width: 60, height: 60 } }, sq(0, 0, 40, RED), sq(20, 20, 40, BLUE)),
    f: () => h(View, { style: { width: 60, height: 60 } }, sq(0, 0, 40, RED, { zIndex: 2 }), sq(20, 20, 40, BLUE)) },
  { id: 'absNegative',
    c: () => h(View, { style: { width: 60, height: 60, backgroundColor: 'rgb(200,200,200)' } }, sq(5, 5, 20, RED)),
    f: () => h(View, { style: { width: 60, height: 60, backgroundColor: 'rgb(200,200,200)' } }, sq(-15, -15, 20, RED)) },
  { id: 'aspectRatio', c: () => box({ width: 60, height: undefined, aspectRatio: 1 }), f: () => box({ width: 60, height: undefined, aspectRatio: 2 }) },
  { id: 'gap',
    c: () => h(View, { style: { flexDirection: 'row' } }, box({ width: 20, height: 20 }), box({ width: 20, height: 20, backgroundColor: RED })),
    f: () => h(View, { style: { flexDirection: 'row', gap: 10 } }, box({ width: 20, height: 20 }), box({ width: 20, height: 20, backgroundColor: RED })) },
  { id: 'rowColumnGap',
    c: () => h(View, { style: { width: 60, flexDirection: 'row', flexWrap: 'wrap' } }, box({ width: 25, height: 20 }), box({ width: 25, height: 20, backgroundColor: RED }), box({ width: 25, height: 20, backgroundColor: GREEN })),
    f: () => h(View, { style: { width: 60, flexDirection: 'row', flexWrap: 'wrap', columnGap: 10, rowGap: 6 } }, box({ width: 25, height: 20 }), box({ width: 25, height: 20, backgroundColor: RED }), box({ width: 25, height: 20, backgroundColor: GREEN })) },
  { id: 'flexWrap',
    c: () => h(View, { style: { width: 60, flexDirection: 'row' } }, box({ width: 25, height: 20, flexShrink: 0 }), box({ width: 25, height: 20, flexShrink: 0, backgroundColor: RED }), box({ width: 25, height: 20, flexShrink: 0, backgroundColor: GREEN })),
    f: () => h(View, { style: { width: 60, flexDirection: 'row', flexWrap: 'wrap' } }, box({ width: 25, height: 20, flexShrink: 0 }), box({ width: 25, height: 20, flexShrink: 0, backgroundColor: RED }), box({ width: 25, height: 20, flexShrink: 0, backgroundColor: GREEN })) },
  // ---- text ----
  { id: 'letterSpacing', c: () => txt('IIII'), f: () => txt('IIII', { letterSpacing: 8 }) },
  { id: 'lineHeight', c: () => txt('A\nA', { fontSize: 16 }), f: () => txt('A\nA', { fontSize: 16, lineHeight: 40 }) },
  { id: 'underline', c: () => txt('AAAA'), f: () => txt('AAAA', { textDecorationLine: 'underline' }) },
  { id: 'lineThrough', c: () => txt('AAAA'), f: () => txt('AAAA', { textDecorationLine: 'line-through' }) },
  { id: 'decorationColor', c: () => txt('AAAA', { textDecorationLine: 'underline' }), f: () => txt('AAAA', { textDecorationLine: 'underline', textDecorationColor: RED, textDecorationStyle: 'dashed' }) },
  { id: 'textTransform', c: () => txt('ABC'), f: () => txt('abc', { textTransform: 'uppercase' }) },
  { id: 'tabularNums', c: () => h(View, null, txt('1111'), txt('0000')), f: () => h(View, null, txt('1111', { fontVariant: ['tabular-nums'] }), txt('0000', { fontVariant: ['tabular-nums'] })) },
  { id: 'fontWeight', c: () => txt('Ab', { fontSize: 32, fontWeight: '100' }), f: () => txt('Ab', { fontSize: 32, fontWeight: '900' }) },
  { id: 'fontWeightBold', c: () => txt('Ab', { fontSize: 32 }), f: () => txt('Ab', { fontSize: 32, fontWeight: 'bold' }) },
  { id: 'italic', c: () => txt('IIII', { fontSize: 32 }), f: () => txt('IIII', { fontSize: 32, fontStyle: 'italic' }) },
  { id: 'numberOfLines', c: () => h(View, { style: { width: 80 } }, txt('AAAA BBBB CCCC DDDD', { fontSize: 14 })), f: () => h(View, { style: { width: 80 } }, txt('AAAA BBBB CCCC DDDD', { fontSize: 14 }, { numberOfLines: 1 })) },
  { id: 'ellipsizeHead', c: () => h(View, { style: { width: 80 } }, txt('ABCDEFGHIJKLMNOP', { fontSize: 14 }, { numberOfLines: 1, ellipsizeMode: 'tail' })), f: () => h(View, { style: { width: 80 } }, txt('ABCDEFGHIJKLMNOP', { fontSize: 14 }, { numberOfLines: 1, ellipsizeMode: 'head' })) },
  { id: 'ellipsizeMiddle', c: () => h(View, { style: { width: 80 } }, txt('ABCDEFGHIJKLMNOP', { fontSize: 14 }, { numberOfLines: 1, ellipsizeMode: 'tail' })), f: () => h(View, { style: { width: 80 } }, txt('ABCDEFGHIJKLMNOP', { fontSize: 14 }, { numberOfLines: 1, ellipsizeMode: 'middle' })) },
  { id: 'writingDirection', c: () => h(View, { style: { width: 80 } }, txt('AB')), f: () => h(View, { style: { width: 80 } }, txt('AB', { writingDirection: 'rtl' })) },
  { id: 'textAlignCenter', c: () => h(View, { style: { width: 80 } }, txt('AB')), f: () => h(View, { style: { width: 80 } }, txt('AB', { textAlign: 'center' })) },
  { id: 'textAlignRight', c: () => h(View, { style: { width: 80 } }, txt('AB')), f: () => h(View, { style: { width: 80 } }, txt('AB', { textAlign: 'right' })) },
  { id: 'textAlignJustify', c: () => h(View, { style: { width: 80 } }, txt('I I I IIIIIIII', { fontSize: 14 })), f: () => h(View, { style: { width: 80 } }, txt('I I I IIIIIIII', { fontSize: 14, textAlign: 'justify' })) },
  { id: 'nestedText', c: () => txt('AABB'), f: () => txt(['AA', h(Text, { key: 'r', style: { color: RED } }, 'BB')]) },
  { id: 'nestedTextSize', c: () => txt('AAAA', { fontSize: 14 }), f: () => txt(['AA', h(Text, { key: 'r', style: { fontSize: 30 } }, 'AA')], { fontSize: 14 }) },
  { id: 'textBackground', c: () => txt('AB'), f: () => txt(['A', h(Text, { key: 'r', style: { backgroundColor: 'rgb(0,255,0)' } }, 'B')]) },
  // ---- components ----
  { id: 'image', c: () => box({ backgroundColor: 'rgb(200,200,200)' }), f: () => h(Image, { source: { uri: RED_PNG }, style: { width: 60, height: 60 } }) },
  { id: 'imageTint', c: () => h(Image, { source: { uri: RED_PNG }, style: { width: 60, height: 60 } }), f: () => h(Image, { source: { uri: RED_PNG }, style: { width: 60, height: 60, tintColor: BLUE } }) },
  { id: 'scrollContentOffset',
    c: () => h(ScrollView, { style: { width: 60, height: 60 } }, sq(0, 0, 0, RED, { position: 'relative', width: 60, height: 30 }), sq(0, 0, 0, BLUE, { position: 'relative', width: 60, height: 90 })),
    f: () => h(ScrollView, { style: { width: 60, height: 60 }, contentOffset: { x: 0, y: 30 } }, sq(0, 0, 0, RED, { position: 'relative', width: 60, height: 30 }), sq(0, 0, 0, BLUE, { position: 'relative', width: 60, height: 90 })) },
  { id: 'scrollHorizontal',
    c: () => h(ScrollView, { horizontal: true, style: { width: 60, height: 60 } }, sq(0, 0, 0, RED, { position: 'relative', width: 30, height: 60 }), sq(0, 0, 0, BLUE, { position: 'relative', width: 90, height: 60 })),
    f: () => h(ScrollView, { horizontal: true, style: { width: 60, height: 60 }, contentOffset: { x: 30, y: 0 } }, sq(0, 0, 0, RED, { position: 'relative', width: 30, height: 60 }), sq(0, 0, 0, BLUE, { position: 'relative', width: 90, height: 60 })) },
  { id: 'activityIndicator', c: () => h(View, { style: { width: 60, height: 60 } }), f: () => h(ActivityIndicator, { size: 'large', color: RED, style: { width: 60, height: 60 } }) },
  { id: 'switch', c: () => h(View, { style: { width: 60, height: 40 } }), f: () => h(Switch, { value: true, trackColor: { true: RED, false: BLUE }, thumbColor: GREEN }) },
  { id: 'textInputMultiline',
    c: () => h(TextInput, { value: 'L1', style: { width: 80, height: 60, fontSize: 14, color: BLACK } }),
    f: () => h(TextInput, { multiline: true, value: 'L1\nL2\nL3', style: { width: 80, height: 60, fontSize: 14, color: BLACK } }) },
  { id: 'textInputSecure',
    c: () => h(TextInput, { value: 'abc', style: { width: 80, height: 40, fontSize: 16, color: BLACK } }),
    f: () => h(TextInput, { value: 'abc', secureTextEntry: true, style: { width: 80, height: 40, fontSize: 16, color: BLACK } }) },
  { id: 'placeholderColor',
    c: () => h(TextInput, { value: '', placeholder: 'Ph', style: { width: 80, height: 40, fontSize: 16 } }),
    f: () => h(TextInput, { value: '', placeholder: 'Ph', placeholderTextColor: RED, style: { width: 80, height: 40, fontSize: 16 } }) },
  { id: 'statusBar', c: () => box(), f: () => h(View, null, h(StatusBar, { hidden: true, barStyle: 'light-content' }), box()) },
];

const CELL_W = 240, CELL_H = 150, PER_ROW = 5;

function Cell(props) {
  const { t, i } = props;
  const cx = (i % PER_ROW) * CELL_W, cy = Math.floor(i / PER_ROW) * CELL_H;
  return h(View, { style: { position: 'absolute', left: cx, top: cy, width: CELL_W, height: CELL_H } },
    h(Text, { style: { position: 'absolute', left: 4, top: 1, fontSize: 10, color: 'rgb(120,120,120)' } }, (i + 1) + ' ' + t.id),
    h(View, { style: { position: 'absolute', left: 30, top: 45 } }, t.c()),
    h(View, { style: { position: 'absolute', left: 150, top: 45 } }, t.f()));
}

function Grid() {
  return h(View, { style: { flex: 1, backgroundColor: 'white' } }, TESTS.map((t, i) => h(Cell, { key: t.id, t, i })));
}

const hit = () => Alert.alert('probe', 'hit');

function TapScene(props) {
  const s = props.scene;
  if (s === 'tap-boxnone' || s === 'tap-auto') {
    return h(View, { style: { flex: 1, backgroundColor: 'white' } },
      h(Pressable, { onPress: hit, style: { position: 'absolute', left: 0, top: 0, width: 200, height: 200, backgroundColor: BLUE } }),
      h(View, { collapsable: false, pointerEvents: s === 'tap-boxnone' ? 'box-none' : 'auto', style: { position: 'absolute', left: 0, top: 0, width: 200, height: 200 } },
        sq(0, 0, 20, RED)));
  }
  if (s === 'sticky' || s === 'sticky-control') {
    // A 200pt ScrollView: red 40pt header then ten 60pt blue/green rows.
    // After a wheel scroll down, a sticky header (index 0) still covers y 0..40.
    const rows = [h(View, { key: 'hd', style: { height: 40, backgroundColor: RED } })];
    for (let k = 0; k < 10; k++) rows.push(h(View, { key: 'r' + k, style: { height: 60, backgroundColor: k % 2 ? GREEN : BLUE } }));
    return h(View, { style: { flex: 1, backgroundColor: 'white' } },
      h(ScrollView, { style: { width: 200, height: 200 }, stickyHeaderIndices: s === 'sticky' ? [0] : undefined }, rows));
  }
  if (s === 'snap' || s === 'snap-control') {
    // Rows are 60pt. One wheel notch scrolls 40pt. With snapToInterval 60 the
    // list must settle on 0 or 60, so viewport y 0..20 is never a row seam at 20.
    const rows = [];
    for (let k = 0; k < 12; k++) rows.push(h(View, { key: 'r' + k, style: { height: 60, backgroundColor: k % 2 ? GREEN : BLUE } }));
    return h(View, { style: { flex: 1, backgroundColor: 'white' } },
      h(ScrollView, { style: { width: 200, height: 200 }, snapToInterval: s === 'snap' ? 60 : undefined, decelerationRate: 'fast' }, rows));
  }
  if (s === 'hscroll') {
    // Horizontal list: red 60pt column then blue/green 60pt columns; a
    // horizontal wheel moves it left. Control is the frame before the wheel.
    const cols = [];
    for (let k = 0; k < 12; k++) cols.push(h(View, { key: 'c' + k, style: { width: 60, height: 200, backgroundColor: k === 0 ? RED : k % 2 ? GREEN : BLUE } }));
    return h(View, { style: { flex: 1, backgroundColor: 'white' } },
      h(ScrollView, { horizontal: true, style: { width: 200, height: 200 } }, cols));
  }
  if (s === 'select' || s === 'select-control') {
    // A drag across selectable text should paint a selection highlight.
    // select-control renders the same text and is captured without a drag.
    return h(View, { style: { flex: 1, backgroundColor: 'white' } },
      h(Text, { selectable: true, style: { position: 'absolute', left: 20, top: 100, fontSize: 32, color: BLACK } }, 'SELECT ME'));
  }
  if (s === 'tap-pressin') {
    return h(View, { style: { flex: 1, backgroundColor: 'white' } },
      h(Pressable, { onPressIn: hit, style: { position: 'absolute', left: 100, top: 100, width: 40, height: 40, backgroundColor: BLUE } }));
  }
  if (s === 'tap-hitslop' || s === 'tap-noslop') {
    return h(View, { style: { flex: 1, backgroundColor: 'white' } },
      h(Pressable, { onPress: hit, hitSlop: s === 'tap-hitslop' ? 20 : undefined, style: { position: 'absolute', left: 100, top: 100, width: 40, height: 40, backgroundColor: BLUE } }));
  }
  if (s === 'modal') {
    // The Modal is the FIRST child and a full-screen blue View comes AFTER it.
    // On RN the modal presents above the whole app, so its red box is visible.
    // If Modal mounts as an ordinary in-tree View the later blue sibling covers it.
    return h(View, { style: { flex: 1, backgroundColor: 'white' } },
      h(Modal, { visible: true, transparent: true }, sq(100, 100, 60, RED)),
      sq(0, 0, 400, BLUE));
  }
  return h(Grid);
}

function Probe() {
  const [scene, setScene] = React.useState(null);
  React.useEffect(() => {
    Linking.getInitialURL().then((u) => setScene((u || 'probe://grid').replace('probe://', ''))).catch(() => setScene('grid'));
  }, []);
  if (scene === null) return h(View, { style: { flex: 1, backgroundColor: 'white' } });
  return h(TapScene, { scene });
}

AppRegistry.registerComponent('probe', () => Probe);
