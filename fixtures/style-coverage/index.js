/**
 * STYLE COVERAGE GRID 2 for react-native-impeller. Same cell contract as
 * fixtures/style-audit (240x150 cells, 5 per row, CONTROL slot at +30,+45,
 * FEATURE slot at +150,+45). Covers every RN 0.86 style key and visual prop
 * NOT already in grid 1. `e` is the expectation used when judging the frame:
 *   'diff'  the feature slot must differ from the control slot
 *   'same'  the feature slot must equal the control slot (colour syntaxes)
 * Scenes: probe://g2 (default), probe://risky (props that could throw).
 */
const React = require('react');
const RN = require('react-native');
const {
  AppRegistry, View, Text, ScrollView, ImageBackground, Switch, TextInput,
  Button, Linking, PlatformColor,
} = RN;
const h = React.createElement;

const BLUE = 'rgb(0,0,255)';
const RED = 'rgb(255,0,0)';
const GREEN = 'rgb(0,255,0)';
const BLACK = 'rgb(0,0,0)';
const GREY = 'rgb(200,200,200)';
const box = (extra) => h(View, { style: [{ width: 60, height: 60, backgroundColor: BLUE }, extra] });
const sq = (x, y, s, c, extra) =>
  h(View, { style: [{ position: 'absolute', left: x, top: y, width: s, height: s, backgroundColor: c }, extra] });
const txt = (s, style, props) => h(Text, Object.assign({ style: [{ fontSize: 20, color: BLACK }, style] }, props || {}), s);
const frame = (style, ...kids) => h(View, { style: [{ width: 60, height: 60, backgroundColor: GREY }, style] }, ...kids);
const wbox = (extra) => box([{ backgroundColor: 'white', borderWidth: 4, borderColor: BLACK }, extra]);
const ti = (extra, props) => h(TextInput, Object.assign({ value: 'ab', style: [{ width: 80, height: 40, fontSize: 16, color: BLACK }, extra] }, props || {}));
const row = (style, ...kids) => h(View, { style: [{ width: 60, height: 60, flexDirection: 'row', backgroundColor: GREY }, style] }, ...kids);
const chip = (c, extra) => h(View, { style: [{ width: 20, height: 20, backgroundColor: c }, extra] });

const TESTS = [
  // ---- layout (Yoga) ----
  { id: 'displayNone', e: 'diff', c: () => box(), f: () => box({ display: 'none' }) },
  { id: 'displayContents', e: 'diff',
    c: () => h(View, { style: { backgroundColor: RED, padding: 15, width: 60, height: 60 } }, chip(BLUE, { width: 30, height: 30 })),
    f: () => h(View, { style: { backgroundColor: RED, padding: 15, width: 60, height: 60, display: 'contents' } }, chip(BLUE, { width: 30, height: 30 })) },
  { id: 'positionStatic', e: 'diff',
    c: () => frame(null, h(View, { style: { marginLeft: 30, marginTop: 30, width: 30, height: 30, backgroundColor: GREEN } }, sq(0, 0, 15, RED))),
    f: () => frame(null, h(View, { style: { position: 'static', marginLeft: 30, marginTop: 30, width: 30, height: 30, backgroundColor: GREEN } }, sq(0, 0, 15, RED))) },
  { id: 'boxSizingContent', e: 'diff', c: () => box({ width: 40, height: 40, padding: 10 }), f: () => box({ width: 40, height: 40, padding: 10, boxSizing: 'content-box' }) },
  { id: 'directionRtl', e: 'diff', c: () => row(null, chip(BLUE), chip(RED)), f: () => row({ direction: 'rtl' }, chip(BLUE), chip(RED)) },
  { id: 'insetLogical', e: 'diff', c: () => frame(null, sq(0, 0, 20, RED)), f: () => frame(null, h(View, { style: { position: 'absolute', top: 0, insetInlineEnd: 0, width: 20, height: 20, backgroundColor: RED } })) },
  { id: 'insetShorthand', e: 'diff', c: () => frame(null, sq(0, 0, 20, RED)), f: () => frame(null, h(View, { style: { position: 'absolute', inset: 10, backgroundColor: RED } })) },
  { id: 'marginLogical', e: 'diff', c: () => frame(null, chip(BLUE)), f: () => frame(null, chip(BLUE, { marginInlineStart: 30, marginBlockStart: 20 })) },
  { id: 'paddingLogical', e: 'diff', c: () => frame(null, chip(BLUE)), f: () => frame({ paddingBlock: 20, paddingInline: 20 }, chip(BLUE)) },
  { id: 'startEnd', e: 'diff', c: () => frame(null, sq(0, 0, 20, RED)), f: () => frame(null, h(View, { style: { position: 'absolute', top: 0, start: 30, width: 20, height: 20, backgroundColor: RED } })) },
  { id: 'spaceEvenly', e: 'diff', c: () => row(null, chip(BLUE, { width: 10 }), chip(RED, { width: 10 })), f: () => row({ justifyContent: 'space-evenly' }, chip(BLUE, { width: 10 }), chip(RED, { width: 10 })) },
  { id: 'alignContent', e: 'diff',
    c: () => row({ flexWrap: 'wrap' }, chip(BLUE, { width: 40 }), chip(RED, { width: 40 })),
    f: () => row({ flexWrap: 'wrap', alignContent: 'flex-end' }, chip(BLUE, { width: 40 }), chip(RED, { width: 40 })) },
  { id: 'percentSize', e: 'diff', c: () => frame(null, chip(BLUE, { width: 60, height: 60 })), f: () => frame(null, chip(BLUE, { width: '50%', height: '50%' })) },
  { id: 'maxWidth', e: 'diff', c: () => box(), f: () => box({ maxWidth: 30 }) },
  { id: 'flexGrow', e: 'diff', c: () => row(null, chip(BLUE), chip(RED)), f: () => row(null, chip(BLUE, { flexGrow: 1 }), chip(RED)) },
  { id: 'overflowScroll', e: 'diff',
    c: () => h(View, { style: { width: 60, height: 60 } }, sq(-15, -15, 90, RED)),
    f: () => h(View, { style: { width: 60, height: 60, overflow: 'scroll' } }, sq(-15, -15, 90, RED)) },
  { id: 'zIndexNegative', e: 'diff',
    c: () => h(View, { style: { width: 60, height: 60 } }, sq(0, 0, 40, RED), sq(20, 20, 40, BLUE)),
    f: () => h(View, { style: { width: 60, height: 60 } }, sq(0, 0, 40, RED), sq(20, 20, 40, BLUE, { zIndex: -1 })) },
  { id: 'aspectRatioWidth', e: 'diff', c: () => box({ height: 30, width: undefined, aspectRatio: 1 }), f: () => box({ height: 30, width: undefined, aspectRatio: 2 }) },
  // ---- borders ----
  { id: 'borderLogicalWidth', e: 'diff', c: () => wbox(), f: () => wbox({ borderStartWidth: 12, borderStartColor: RED }) },
  { id: 'borderBlockColor', e: 'diff', c: () => wbox(), f: () => wbox({ borderBlockColor: RED }) },
  { id: 'borderLogicalRadius', e: 'diff', c: () => box(), f: () => box({ borderStartStartRadius: 30, borderEndEndRadius: 30 }) },
  { id: 'ellipticalRadius', e: 'diff', c: () => box({ width: 90, height: 45 }), f: () => box({ width: 90, height: 45, borderRadius: '50%' }) },
  { id: 'radiusUnevenWidth', e: 'diff',
    c: () => box({ backgroundColor: 'white', borderRadius: 16, borderWidth: 4, borderColor: BLUE }),
    f: () => box({ backgroundColor: 'white', borderRadius: 16, borderWidth: 2, borderTopWidth: 12, borderColor: BLUE }) },
  { id: 'dashedRounded', e: 'diff',
    c: () => box({ backgroundColor: 'white', borderRadius: 16, borderWidth: 4, borderColor: BLACK }),
    f: () => box({ backgroundColor: 'white', borderRadius: 16, borderWidth: 4, borderColor: BLACK, borderStyle: 'dashed' }) },
  { id: 'dashedPerSideColor', e: 'diff',
    c: () => wbox({ borderStyle: 'dashed' }),
    f: () => wbox({ borderStyle: 'dashed', borderTopColor: RED }) },
  { id: 'borderAlphaOverBg', e: 'diff',
    c: () => box({ borderWidth: 10, borderColor: RED }),
    f: () => box({ borderWidth: 10, borderColor: 'rgba(255,0,0,0.5)' }) },
  { id: 'borderCurve', e: 'diff', c: () => box({ borderRadius: 24 }), f: () => box({ borderRadius: 24, borderCurve: 'continuous' }) },
  { id: 'borderNoColor', e: 'diff', c: () => box({ backgroundColor: 'white' }), f: () => box({ backgroundColor: 'white', borderWidth: 4 }) },
  { id: 'roundedPerSideWidthColor', e: 'diff',
    c: () => box({ backgroundColor: 'white', borderRadius: 16, borderWidth: 4, borderColor: BLACK }),
    f: () => box({ backgroundColor: 'white', borderRadius: 16, borderTopWidth: 8, borderTopColor: RED, borderLeftWidth: 4, borderLeftColor: GREEN, borderRightWidth: 4, borderRightColor: BLACK, borderBottomWidth: 4, borderBottomColor: BLUE }) },
  // ---- backgrounds ----
  { id: 'gradientAngle', e: 'diff', c: () => box({ experimental_backgroundImage: 'linear-gradient(to right, rgb(255,0,0), rgb(0,0,255))' }), f: () => box({ experimental_backgroundImage: 'linear-gradient(45deg, rgb(255,0,0), rgb(0,0,255))' }) },
  { id: 'gradientHardStops', e: 'diff', c: () => box({ experimental_backgroundImage: 'linear-gradient(to right, rgb(255,0,0), rgb(0,0,255))' }), f: () => box({ experimental_backgroundImage: 'linear-gradient(to right, rgb(255,0,0) 0%, rgb(255,0,0) 50%, rgb(0,0,255) 50%, rgb(0,0,255) 100%)' }) },
  { id: 'gradientLayers', e: 'diff',
    c: () => box({ experimental_backgroundImage: 'linear-gradient(to right, rgb(255,0,0), rgb(0,0,255))' }),
    f: () => box({ experimental_backgroundImage: 'linear-gradient(to bottom, rgba(0,0,0,0.8), rgba(0,0,0,0)), linear-gradient(to right, rgb(255,0,0), rgb(0,0,255))' }) },
  { id: 'gradientRounded', e: 'diff', c: () => box({ experimental_backgroundImage: 'linear-gradient(to right, rgb(255,0,0), rgb(0,0,255))' }), f: () => box({ borderRadius: 30, experimental_backgroundImage: 'linear-gradient(to right, rgb(255,0,0), rgb(0,0,255))' }) },
  { id: 'gradientOverBgColor', e: 'diff', c: () => box({ backgroundColor: GREEN }), f: () => box({ backgroundColor: GREEN, experimental_backgroundImage: 'linear-gradient(to right, rgba(255,0,0,1), rgba(255,0,0,0))' }) },
  { id: 'backgroundSize', e: 'diff',
    c: () => box({ experimental_backgroundImage: 'linear-gradient(to right, rgb(255,0,0), rgb(0,0,255))' }),
    f: () => box({ experimental_backgroundImage: 'linear-gradient(to right, rgb(255,0,0), rgb(0,0,255))', experimental_backgroundSize: '20px 20px', experimental_backgroundRepeat: 'repeat' }) },
  { id: 'backgroundPosition', e: 'diff',
    c: () => box({ backgroundColor: GREY, experimental_backgroundImage: 'linear-gradient(to right, rgb(255,0,0), rgb(0,0,255))' }),
    f: () => box({ backgroundColor: GREY, experimental_backgroundImage: 'linear-gradient(to right, rgb(255,0,0), rgb(0,0,255))', experimental_backgroundSize: '30px 30px', experimental_backgroundPosition: 'center', experimental_backgroundRepeat: 'no-repeat' }) },
  { id: 'gradientColorHint', e: 'diff', c: () => box({ experimental_backgroundImage: 'linear-gradient(to right, rgb(255,0,0), rgb(0,0,255))' }), f: () => box({ experimental_backgroundImage: 'linear-gradient(to right, rgb(255,0,0), 15%, rgb(0,0,255))' }) },
  // ---- shadows ----
  { id: 'boxShadowMulti', e: 'diff', c: () => box(), f: () => box({ boxShadow: '6px 6px 0px rgb(255,0,0), -6px -6px 0px rgb(0,255,0)' }) },
  { id: 'boxShadowSpread', e: 'diff', c: () => box(), f: () => box({ boxShadow: '0px 0px 0px 8px rgb(255,0,0)' }) },
  { id: 'boxShadowRounded', e: 'diff', c: () => box({ borderRadius: 30 }), f: () => box({ borderRadius: 30, boxShadow: '6px 6px 6px rgba(0,0,0,0.9)' }) },
  { id: 'boxShadowObject', e: 'diff', c: () => box(), f: () => box({ boxShadow: [{ offsetX: 6, offsetY: 6, blurRadius: 4, color: 'rgba(0,0,0,0.9)' }] }) },
  { id: 'shadowNoBg', e: 'diff',
    c: () => h(View, { style: { width: 60, height: 60 } }, sq(15, 15, 30, RED)),
    f: () => h(View, { style: { width: 60, height: 60, shadowColor: BLACK, shadowOffset: { width: 6, height: 6 }, shadowOpacity: 0.9, shadowRadius: 3 } }, sq(15, 15, 30, RED)) },
  { id: 'shadowOpacityOnly', e: 'diff', c: () => box(), f: () => box({ shadowOpacity: 1 }) },
  { id: 'elevationRounded', e: 'diff', c: () => box({ borderRadius: 20 }), f: () => box({ borderRadius: 20, elevation: 10 }) },
  // ---- transforms ----
  { id: 'rotateZ', e: 'diff', c: () => box({ width: 40, height: 40 }), f: () => box({ width: 40, height: 40, transform: [{ rotateZ: '45deg' }] }) },
  { id: 'rotateX', e: 'diff', c: () => box(), f: () => box({ transform: [{ rotateX: '60deg' }] }) },
  { id: 'scaleXY', e: 'diff', c: () => box({ width: 40, height: 40 }), f: () => box({ width: 40, height: 40, transform: [{ scaleX: 0.5 }, { scaleY: 1.4 }] }) },
  { id: 'skewY', e: 'diff', c: () => box({ width: 40, height: 40 }), f: () => box({ width: 40, height: 40, transform: [{ skewY: '30deg' }] }) },
  { id: 'translatePercent', e: 'diff', c: () => box({ width: 40, height: 40 }), f: () => box({ width: 40, height: 40, transform: [{ translateX: '50%' }] }) },
  { id: 'matrix', e: 'diff', c: () => box({ width: 40, height: 40 }), f: () => box({ width: 40, height: 40, transform: [{ matrix: [0.5, 0, 0, 0, 0, 0.5, 0, 0, 0, 0, 1, 0, 20, 0, 0, 1] }] }) },
  { id: 'transformString', e: 'diff', c: () => box({ width: 40, height: 40 }), f: () => box({ width: 40, height: 40, transform: 'rotate(45deg) scale(0.5)' }) },
  { id: 'transformOriginPx', e: 'diff', c: () => box({ width: 40, height: 40, transform: [{ rotate: '30deg' }] }), f: () => box({ width: 40, height: 40, transformOrigin: '0px 0px', transform: [{ rotate: '30deg' }] }) },
  { id: 'perspectiveRotateX', e: 'diff', c: () => box({ transform: [{ rotateX: '50deg' }] }), f: () => box({ transform: [{ perspective: 120 }, { rotateX: '50deg' }] }) },
  { id: 'nestedTransform', e: 'diff',
    c: () => h(View, { style: { width: 60, height: 60, backgroundColor: GREY } }, sq(20, 0, 20, RED)),
    f: () => h(View, { style: { width: 60, height: 60, backgroundColor: GREY, transform: [{ rotate: '45deg' }] } }, sq(20, 0, 20, RED, { transform: [{ translateY: 20 }] })) },
  // ---- filters / outline (beyond grid 1) ----
  { id: 'filterInvert', e: 'diff', c: () => box(), f: () => box({ filter: 'invert(1)' }) },
  { id: 'filterHueRotate', e: 'diff', c: () => box({ backgroundColor: RED }), f: () => box({ backgroundColor: RED, filter: 'hue-rotate(180deg)' }) },
  { id: 'filterOpacity', e: 'diff', c: () => box(), f: () => box({ filter: 'opacity(0.3)' }) },
  { id: 'filterSaturate', e: 'diff', c: () => box({ backgroundColor: RED }), f: () => box({ backgroundColor: RED, filter: 'saturate(0)' }) },
  { id: 'outlineDashed', e: 'diff', c: () => box(), f: () => box({ outlineWidth: 3, outlineColor: RED, outlineStyle: 'dashed' }) },
  // ---- colour syntaxes (must equal the control) ----
  { id: 'colorHsl', e: 'same', c: () => box(), f: () => box({ backgroundColor: 'hsl(240, 100%, 50%)' }) },
  { id: 'colorHwb', e: 'same', c: () => box(), f: () => box({ backgroundColor: 'hwb(240, 0%, 0%)' }) },
  { id: 'colorHex4', e: 'same', c: () => box(), f: () => box({ backgroundColor: '#00ff' }) },
  { id: 'colorNamed', e: 'same', c: () => box(), f: () => box({ backgroundColor: 'blue' }) },
  { id: 'colorAlpha', e: 'same', c: () => box({ backgroundColor: 'rgb(127,127,255)' }), f: () => box({ backgroundColor: 'rgba(0,0,255,0.5)' }) },
  // ---- text ----
  { id: 'smallCaps', e: 'diff', c: () => txt('Abc'), f: () => txt('Abc', { fontVariant: ['small-caps'] }) },
  { id: 'decoBoth', e: 'diff', c: () => txt('AAAA', { textDecorationLine: 'underline' }), f: () => txt('AAAA', { textDecorationLine: 'underline line-through' }) },
  { id: 'decoDouble', e: 'diff', c: () => txt('AAAA', { textDecorationLine: 'underline' }), f: () => txt('AAAA', { textDecorationLine: 'underline', textDecorationStyle: 'double' }) },
  { id: 'decoDotted', e: 'diff', c: () => txt('AAAA', { textDecorationLine: 'underline' }), f: () => txt('AAAA', { textDecorationLine: 'underline', textDecorationStyle: 'dotted' }) },
  { id: 'textAlignVertical', e: 'diff', c: () => txt('AB', { height: 60, width: 60, backgroundColor: GREY }), f: () => txt('AB', { height: 60, width: 60, backgroundColor: GREY, textAlignVertical: 'center' }) },
  { id: 'verticalAlign', e: 'diff', c: () => txt('AB', { height: 60, width: 60, backgroundColor: GREY }), f: () => txt('AB', { height: 60, width: 60, backgroundColor: GREY, verticalAlign: 'middle' }) },
  { id: 'adjustsFontSize', e: 'diff',
    c: () => h(View, { style: { width: 80 } }, txt('ABCDEFGHIJ', { fontSize: 24 }, { numberOfLines: 1 })),
    f: () => h(View, { style: { width: 80 } }, txt('ABCDEFGHIJ', { fontSize: 24 }, { numberOfLines: 1, adjustsFontSizeToFit: true, minimumFontScale: 0.2 })) },
  { id: 'fontMonospace', e: 'diff', c: () => txt('iiMM'), f: () => txt('iiMM', { fontFamily: 'monospace' }) },
  { id: 'fontSerif', e: 'diff', c: () => txt('Ag'), f: () => txt('Ag', { fontFamily: 'serif' }) },
  { id: 'textColorAlpha', e: 'diff', c: () => txt('AB'), f: () => txt('AB', { color: 'rgba(0,0,0,0.3)' }) },
  { id: 'textOpacity', e: 'diff', c: () => txt('AB'), f: () => txt('AB', { opacity: 0.3 }) },
  { id: 'nestedWeight', e: 'diff', c: () => txt('AABB'), f: () => txt(['AA', h(Text, { key: 'r', style: { fontWeight: 'bold' } }, 'BB')]) },
  { id: 'nestedItalic', e: 'diff', c: () => txt('AABB'), f: () => txt(['AA', h(Text, { key: 'r', style: { fontStyle: 'italic' } }, 'BB')]) },
  { id: 'nestedDeco', e: 'diff', c: () => txt('AABB'), f: () => txt(['AA', h(Text, { key: 'r', style: { textDecorationLine: 'underline' } }, 'BB')]) },
  { id: 'nestedFamily', e: 'diff', c: () => txt('iiii'), f: () => txt(['ii', h(Text, { key: 'r', style: { fontFamily: 'monospace' } }, 'ii')]) },
  { id: 'nestedOpacity', e: 'diff', c: () => txt('AABB'), f: () => txt(['AA', h(Text, { key: 'r', style: { opacity: 0.2 } }, 'BB')]) },
  { id: 'capitalize', e: 'diff', c: () => txt('ab cd'), f: () => txt('ab cd', { textTransform: 'capitalize' }) },
  { id: 'lowercase', e: 'diff', c: () => txt('ABC'), f: () => txt('ABC', { textTransform: 'lowercase' }) },
  { id: 'ellipsizeClip', e: 'diff',
    c: () => h(View, { style: { width: 80 } }, txt('ABCDEFGHIJKLMNOP', { fontSize: 14 }, { numberOfLines: 1 })),
    f: () => h(View, { style: { width: 80 } }, txt('ABCDEFGHIJKLMNOP', { fontSize: 14 }, { numberOfLines: 1, ellipsizeMode: 'clip' })) },
  { id: 'numberOfLines2', e: 'diff',
    c: () => h(View, { style: { width: 80 } }, txt('AAAA BBBB CCCC DDDD EEEE', { fontSize: 14 })),
    f: () => h(View, { style: { width: 80 } }, txt('AAAA BBBB CCCC DDDD EEEE', { fontSize: 14 }, { numberOfLines: 2 })) },
  { id: 'textBoxStyle', e: 'diff', c: () => txt('AB'), f: () => txt('AB', { backgroundColor: GREEN, borderRadius: 8, padding: 6, borderWidth: 2, borderColor: RED }) },
  { id: 'textTransformRotate', e: 'diff', c: () => txt('AB'), f: () => txt('AB', { transform: [{ rotate: '90deg' }] }) },
  { id: 'textShadowNested', e: 'diff', c: () => txt('AB', { fontSize: 32, color: RED }), f: () => txt('AB', { fontSize: 32, color: RED, textShadowColor: 'rgba(0,0,255,1)', textShadowOffset: { width: 3, height: 3 }, textShadowRadius: 4 }) },
  { id: 'centerMultiline', e: 'diff',
    c: () => h(View, { style: { width: 80 } }, txt('A\nBBBB', { fontSize: 14 })),
    f: () => h(View, { style: { width: 80 } }, txt('A\nBBBB', { fontSize: 14, textAlign: 'center' })) },
  // ---- TextInput styling ----
  { id: 'tiAlignCenter', e: 'diff', c: () => ti(), f: () => ti({ textAlign: 'center' }) },
  { id: 'tiAlignRight', e: 'diff', c: () => ti(), f: () => ti({ textAlign: 'right' }) },
  { id: 'tiBold', e: 'diff', c: () => ti(), f: () => ti({ fontWeight: 'bold' }) },
  { id: 'tiItalic', e: 'diff', c: () => ti(), f: () => ti({ fontStyle: 'italic' }) },
  { id: 'tiLetterSpacing', e: 'diff', c: () => ti(), f: () => ti({ letterSpacing: 8 }) },
  { id: 'tiPadding', e: 'diff', c: () => ti(), f: () => ti({ paddingLeft: 30 }) },
  { id: 'tiDecoration', e: 'diff', c: () => ti(), f: () => ti({ textDecorationLine: 'underline' }) },
  { id: 'tiBoxStyle', e: 'diff', c: () => ti(), f: () => ti({ borderWidth: 2, borderColor: RED, borderRadius: 8, backgroundColor: 'rgb(255,255,0)' }) },
  { id: 'tiMultiCenter', e: 'diff',
    c: () => ti({ height: 60 }, { multiline: true }),
    f: () => ti({ height: 60, textAlignVertical: 'center' }, { multiline: true }) },
  { id: 'tiMonospace', e: 'diff', c: () => ti(null, { value: 'iiMM' }), f: () => ti({ fontFamily: 'monospace' }, { value: 'iiMM' }) },
  { id: 'tiColor', e: 'diff', c: () => ti(), f: () => ti({ color: RED }) },
  { id: 'tiOpacity', e: 'diff', c: () => ti(), f: () => ti({ opacity: 0.3 }) },
  { id: 'tiTextTransform', e: 'diff', c: () => ti(), f: () => ti({ textTransform: 'uppercase' }) },
  // ---- components ----
  { id: 'imageBackground', e: 'diff', c: () => box({ backgroundColor: GREY }),
    f: () => h(ImageBackground, { source: { uri: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEUlEQVR4nGP8z4AATEhsPBwAM9EBBzDn4UwAAAAASUVORK5CYII=' }, style: { width: 60, height: 60 } }, txt('Hi', { color: BLACK })) },
  { id: 'switchOff', e: 'diff', c: () => h(Switch, { value: true }), f: () => h(Switch, { value: false, trackColor: { false: BLUE }, thumbColor: RED }) },
  { id: 'switchDisabled', e: 'diff', c: () => h(Switch, { value: true }), f: () => h(Switch, { value: true, disabled: true }) },
  { id: 'button', e: 'diff', c: () => h(View, { style: { width: 60, height: 40 } }), f: () => h(Button, { title: 'Go', color: RED, onPress: () => {} }) },
  { id: 'scrollContainerStyle', e: 'diff',
    c: () => h(ScrollView, { style: { width: 60, height: 60 } }, chip(BLUE)),
    f: () => h(ScrollView, { style: { width: 60, height: 60 }, contentContainerStyle: { padding: 10, backgroundColor: RED } }, chip(BLUE)) },
  { id: 'scrollIndicator', e: 'diff',
    c: () => h(ScrollView, { style: { width: 60, height: 60, backgroundColor: GREY }, showsVerticalScrollIndicator: false }, chip(BLUE, { height: 200 })),
    f: () => h(ScrollView, { style: { width: 60, height: 60, backgroundColor: GREY }, showsVerticalScrollIndicator: true, persistentScrollbar: true, indicatorStyle: 'black' }, chip(BLUE, { height: 200 })) },
  { id: 'filterChain', e: 'diff', c: () => box(), f: () => box({ filter: 'brightness(0.5) invert(1)' }) },
];

const RISKY = [
  { id: 'platformColor', e: 'diff', c: () => box({ backgroundColor: GREY }), f: () => box({ backgroundColor: PlatformColor('systemBlue', 'labelColor', '?android:attr/colorAccent') }) },
  { id: 'inlineView', e: 'diff', c: () => txt('ABCD'), f: () => txt(['AB', h(View, { key: 'v', style: { width: 14, height: 14, backgroundColor: RED } }), 'CD']) },
  { id: 'emoji', e: 'diff', c: () => txt('AB'), f: () => txt('A\u{1F642}\u2605') },
  { id: 'cjk', e: 'diff', c: () => txt('AB'), f: () => txt('\u4F60\u597D') },
  { id: 'arabic', e: 'diff', c: () => txt('AB'), f: () => txt('\u0645\u0631\u062D\u0628\u0627') },
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

function Grid(props) {
  return h(View, { style: { flex: 1, backgroundColor: 'white' } }, props.tests.map((t, i) => h(Cell, { key: t.id, t, i })));
}

function Probe() {
  const [scene, setScene] = React.useState(null);
  React.useEffect(() => {
    Linking.getInitialURL().then((u) => setScene((u || 'probe://g2').replace('probe://', ''))).catch(() => setScene('g2'));
  }, []);
  if (scene === null) return h(View, { style: { flex: 1, backgroundColor: 'white' } });
  return h(Grid, { tests: scene === 'risky' ? RISKY : TESTS });
}

global.__GRID2_IDS = { g2: TESTS.map((t) => [t.id, t.e]), risky: RISKY.map((t) => [t.id, t.e]) };
AppRegistry.registerComponent('probe', () => Probe);
