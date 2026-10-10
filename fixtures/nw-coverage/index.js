/**
 * NATIVEWIND COVERAGE PROBE for react-native-impeller (NativeWind 5 rc /
 * react-native-css 3.1 rc / Tailwind 4.1, the versions HostApp pins).
 * Same cell contract as the style grids. CONTROL slot = the hand-written RN
 * style the class should produce; FEATURE slot = the className. e:'same' means
 * the class works when both slots match.
 * Scenes: probe://nw (static utilities), probe://variants (one class per
 * tile on a grey box; control is the bare grey box), probe://interact
 * (hover / press / focus targets at fixed positions).
 */
import './global.css';
import * as RNFF from 'react-native/src/private/featureflags/ReactNativeFeatureFlags';
RNFF.override({shouldPressibilityUseW3CPointerEventsForHover: () => true});
import React from 'react';
import {AppRegistry, View, Text, TextInput, Pressable, Linking} from 'react-native';

const RED = 'rgb(251,44,54)';      // red-500
const BLUE = 'rgb(43,127,255)';    // blue-500
const GREY = 'rgb(200,200,200)';
const B = (style) => <View style={[{width: 60, height: 60, backgroundColor: BLUE}, style]} />;
const N = (cls, style) => <View className={cls} style={style} />;
const chip = (c, extra) => <View style={[{width: 20, height: 20, backgroundColor: c}, extra]} />;
const T = (s, style, props) => <Text style={[{fontSize: 20, color: 'black'}, style]} {...props}>{s}</Text>;
const NT = (s, cls, props) => <Text className={cls} style={{fontSize: 20, color: 'black'}} {...props}>{s}</Text>;

const TESTS = [
  {id: 'bgColor', e: 'same', c: () => B({backgroundColor: RED}), f: () => N('w-[60px] h-[60px] bg-red-500')},
  {id: 'bgOpacityMod', e: 'same', c: () => B({backgroundColor: 'rgba(43,127,255,0.5)'}), f: () => N('w-[60px] h-[60px] bg-blue-500/50')},
  {id: 'arbitraryColor', e: 'same', c: () => B({backgroundColor: '#ff00ff'}), f: () => N('w-[60px] h-[60px] bg-[#ff00ff]')},
  {id: 'cssVariable', e: 'same', c: () => B({backgroundColor: 'rgb(0,255,0)'}), f: () => N('w-[60px] h-[60px] [--brand:#00ff00] bg-(--brand)')},
  {id: 'padding', e: 'same', c: () => <View style={{width: 60, height: 60, backgroundColor: GREY, padding: 16}}>{chip(BLUE)}</View>, f: () => <View className="w-[60px] h-[60px] p-4" style={{backgroundColor: GREY}}>{chip(BLUE)}</View>},
  {id: 'gapRow', e: 'same', c: () => <View style={{flexDirection: 'row', gap: 8}}>{chip(BLUE)}{chip(RED)}</View>, f: () => <View className="flex-row gap-2">{chip(BLUE)}{chip(RED)}</View>},
  {id: 'spaceX', e: 'same', c: () => <View style={{flexDirection: 'row'}}>{chip(BLUE, {marginRight: 8})}{chip(RED)}</View>, f: () => <View className="flex-row space-x-2">{chip(BLUE)}{chip(RED)}</View>},
  {id: 'fraction', e: 'same', c: () => <View style={{width: 60, height: 60, backgroundColor: GREY}}><View style={{width: 30, height: 30, backgroundColor: BLUE}} /></View>, f: () => <View style={{width: 60, height: 60, backgroundColor: GREY}}><View className="w-1/2 h-1/2" style={{backgroundColor: BLUE}} /></View>},
  {id: 'sizeUtil', e: 'same', c: () => B({width: 40, height: 40}), f: () => N('size-10', {backgroundColor: BLUE})},
  {id: 'aspectVideo', e: 'same', c: () => B({width: 64, height: 36}), f: () => N('w-16 aspect-video', {backgroundColor: BLUE})},
  {id: 'flexCenter', e: 'same', c: () => <View style={{width: 60, height: 60, backgroundColor: GREY, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between'}}>{chip(BLUE)}{chip(RED)}</View>, f: () => <View className="w-[60px] h-[60px] flex-row items-center justify-between" style={{backgroundColor: GREY}}>{chip(BLUE)}{chip(RED)}</View>},
  {id: 'absoluteInset', e: 'same', c: () => <View style={{width: 60, height: 60, backgroundColor: GREY}}><View style={{position: 'absolute', left: 8, right: 8, top: 8, height: 16, backgroundColor: RED}} /></View>, f: () => <View style={{width: 60, height: 60, backgroundColor: GREY}}><View className="absolute inset-x-2 top-2 h-4 bg-red-500" /></View>},
  {id: 'roundedXl', e: 'same', c: () => B({borderRadius: 12}), f: () => N('w-[60px] h-[60px] rounded-xl', {backgroundColor: BLUE})},
  {id: 'roundedFull', e: 'same', c: () => B({borderRadius: 30}), f: () => N('w-[60px] h-[60px] rounded-full', {backgroundColor: BLUE})},
  {id: 'roundedTop', e: 'same', c: () => B({borderTopLeftRadius: 8, borderTopRightRadius: 8}), f: () => N('w-[60px] h-[60px] rounded-t-lg', {backgroundColor: BLUE})},
  {id: 'border', e: 'same', c: () => B({backgroundColor: 'white', borderWidth: 2, borderColor: RED}), f: () => N('w-[60px] h-[60px] bg-white border-2 border-red-500')},
  {id: 'borderTop', e: 'same', c: () => B({backgroundColor: 'white', borderTopWidth: 4, borderColor: RED}), f: () => N('w-[60px] h-[60px] bg-white border-t-4 border-red-500')},
  {id: 'borderDashed', e: 'same', c: () => B({backgroundColor: 'white', borderWidth: 2, borderColor: RED, borderStyle: 'dashed'}), f: () => N('w-[60px] h-[60px] bg-white border-2 border-dashed border-red-500')},
  {id: 'divideY', e: 'same', c: () => <View style={{width: 60}}>{chip(BLUE, {width: 60, borderBottomWidth: 2, borderColor: RED})}{chip(GREY, {width: 60})}</View>, f: () => <View className="w-[60px] divide-y-2 divide-red-500">{chip(BLUE, {width: 60})}{chip(GREY, {width: 60})}</View>},
  {id: 'shadowArbitrary', e: 'same', c: () => B({boxShadow: '6px 6px 6px rgba(0,0,0,0.9)'}), f: () => N('w-[60px] h-[60px] shadow-[6px_6px_6px_rgba(0,0,0,0.9)]', {backgroundColor: BLUE})},
  {id: 'shadowLg', e: 'same', c: () => B({boxShadow: '0px 10px 15px -3px rgba(0,0,0,0.1), 0px 4px 6px -4px rgba(0,0,0,0.1)'}), f: () => N('w-[60px] h-[60px] shadow-lg', {backgroundColor: BLUE})},
  {id: 'ring', e: 'same', c: () => B({boxShadow: '0px 0px 0px 4px rgb(251,44,54)'}), f: () => N('w-[60px] h-[60px] ring-4 ring-red-500', {backgroundColor: BLUE})},
  {id: 'opacity', e: 'same', c: () => B({opacity: 0.5}), f: () => N('w-[60px] h-[60px] opacity-50', {backgroundColor: BLUE})},
  {id: 'rotate', e: 'same', c: () => B({width: 40, height: 40, transform: [{rotate: '45deg'}]}), f: () => N('w-10 h-10 rotate-45', {backgroundColor: BLUE})},
  {id: 'scale', e: 'same', c: () => B({width: 40, height: 40, transform: [{scale: 0.5}]}), f: () => N('w-10 h-10 scale-50', {backgroundColor: BLUE})},
  {id: 'translate', e: 'same', c: () => B({width: 40, height: 40, transform: [{translateX: 16}, {translateY: -8}]}), f: () => N('w-10 h-10 translate-x-4 -translate-y-2', {backgroundColor: BLUE})},
  {id: 'skew', e: 'same', c: () => B({width: 40, height: 40, transform: [{skewX: '12deg'}]}), f: () => N('w-10 h-10 skew-x-12', {backgroundColor: BLUE})},
  {id: 'originScale', e: 'same', c: () => B({width: 40, height: 40, transformOrigin: 'top left', transform: [{scale: 0.5}]}), f: () => N('w-10 h-10 origin-top-left scale-50', {backgroundColor: BLUE})},
  {id: 'rotateX3d', e: 'same', c: () => B({transform: [{perspective: 256}, {rotateX: '45deg'}]}), f: () => N('w-[60px] h-[60px] perspective-near rotate-x-45', {backgroundColor: BLUE})},
  {id: 'gradientLinear', e: 'same', c: () => B({experimental_backgroundImage: 'linear-gradient(to right, rgb(251,44,54), rgb(43,127,255))'}), f: () => N('w-[60px] h-[60px] bg-linear-to-r from-red-500 to-blue-500')},
  {id: 'gradientRadial', e: 'same', c: () => B({experimental_backgroundImage: 'radial-gradient(rgb(251,44,54), rgb(43,127,255))'}), f: () => N('w-[60px] h-[60px] bg-radial from-red-500 to-blue-500')},
  {id: 'blur', e: 'same', c: () => B({filter: 'blur(8px)'}), f: () => N('w-[60px] h-[60px] blur-sm', {backgroundColor: BLUE})},
  {id: 'grayscale', e: 'same', c: () => B({backgroundColor: RED, filter: 'grayscale(1)'}), f: () => N('w-[60px] h-[60px] bg-red-500 grayscale')},
  {id: 'blend', e: 'same', c: () => B({mixBlendMode: 'multiply'}), f: () => N('w-[60px] h-[60px] mix-blend-multiply', {backgroundColor: BLUE})},
  {id: 'outline', e: 'same', c: () => B({outlineWidth: 2, outlineColor: RED, outlineStyle: 'solid', outlineOffset: 2}), f: () => N('w-[60px] h-[60px] outline-2 outline-offset-2 outline-red-500', {backgroundColor: BLUE})},
  {id: 'hidden', e: 'same', c: () => <View />, f: () => N('w-[60px] h-[60px] hidden', {backgroundColor: BLUE})},
  {id: 'invisible', e: 'same', c: () => <View />, f: () => N('w-[60px] h-[60px] invisible', {backgroundColor: BLUE})},
  {id: 'overflowHidden', e: 'same', c: () => <View style={{width: 60, height: 60, overflow: 'hidden'}}><View style={{position: 'absolute', left: -15, top: -15, width: 90, height: 90, backgroundColor: RED}} /></View>, f: () => <View className="w-[60px] h-[60px] overflow-hidden"><View style={{position: 'absolute', left: -15, top: -15, width: 90, height: 90, backgroundColor: RED}} /></View>},
  {id: 'textXl', e: 'same', c: () => T('Ab', {fontSize: 20, lineHeight: 28}), f: () => NT('Ab', 'text-xl')},
  {id: 'fontBold', e: 'same', c: () => T('Ab', {fontWeight: '700'}), f: () => NT('Ab', 'font-bold')},
  {id: 'italic', e: 'same', c: () => T('Ab', {fontStyle: 'italic'}), f: () => NT('Ab', 'italic')},
  {id: 'underline', e: 'same', c: () => T('AAAA', {textDecorationLine: 'underline'}), f: () => NT('AAAA', 'underline')},
  {id: 'decoColor', e: 'same', c: () => T('AAAA', {textDecorationLine: 'underline', textDecorationColor: RED, textDecorationStyle: 'dashed'}), f: () => NT('AAAA', 'underline decoration-red-500 decoration-dashed')},
  {id: 'tracking', e: 'same', c: () => T('IIII', {letterSpacing: 2}), f: () => NT('IIII', 'tracking-widest')},
  {id: 'leading', e: 'same', c: () => T('A\nA', {fontSize: 16, lineHeight: 32}), f: () => <Text className="text-base leading-8" style={{color: 'black'}}>{'A\nA'}</Text>},
  {id: 'textCenter', e: 'same', c: () => <View style={{width: 80}}>{T('AB', {textAlign: 'center'})}</View>, f: () => <View style={{width: 80}}>{NT('AB', 'text-center')}</View>},
  {id: 'uppercase', e: 'same', c: () => T('ABC'), f: () => NT('abc', 'uppercase')},
  {id: 'truncate', e: 'same', c: () => <View style={{width: 80}}>{T('ABCDEFGHIJKLMNOP', {fontSize: 14}, {numberOfLines: 1})}</View>, f: () => <View style={{width: 80}}><Text className="truncate text-sm" style={{color: 'black'}}>ABCDEFGHIJKLMNOP</Text></View>},
  {id: 'lineClamp', e: 'same', c: () => <View style={{width: 80}}>{T('AAAA BBBB CCCC DDDD EEEE', {fontSize: 14}, {numberOfLines: 2})}</View>, f: () => <View style={{width: 80}}><Text className="line-clamp-2 text-sm" style={{color: 'black'}}>AAAA BBBB CCCC DDDD EEEE</Text></View>},
  {id: 'fontMono', e: 'diff', c: () => T('iiMM'), f: () => NT('iiMM', 'font-mono')},
  {id: 'tabularNums', e: 'same', c: () => T('1111', {fontVariant: ['tabular-nums']}), f: () => NT('1111', 'tabular-nums')},
  {id: 'textShadow', e: 'same', c: () => T('Ab', {fontSize: 32, color: RED, textShadowColor: 'rgba(0,0,0,0.5)', textShadowOffset: {width: 2, height: 2}, textShadowRadius: 2}), f: () => <Text className="text-shadow-lg text-[32px] text-red-500">Ab</Text>},
  {id: 'textColor', e: 'same', c: () => T('Ab', {color: RED}), f: () => <Text className="text-red-500 text-[20px]">Ab</Text>},
  {id: 'placeholderColor', e: 'same', c: () => <TextInput placeholder="Ph" placeholderTextColor={RED} style={{width: 80, height: 40, fontSize: 16}} />, f: () => <TextInput placeholder="Ph" className="placeholder:text-red-500" style={{width: 80, height: 40, fontSize: 16}} />},
  {id: 'calc', e: 'same', c: () => <View style={{width: 60, height: 60, backgroundColor: GREY}}><View style={{width: 40, height: 20, backgroundColor: BLUE}} /></View>, f: () => <View style={{width: 60, height: 60, backgroundColor: GREY}}><View className="w-[calc(50%+10px)] h-5" style={{backgroundColor: BLUE}} /></View>},
  {id: 'vw', e: 'same', c: () => B({width: 60}), f: () => N('w-[5vw] h-[60px]', {backgroundColor: BLUE})},
  {id: 'backface', e: 'diff', c: () => B({transform: [{rotateY: '180deg'}]}), f: () => N('w-[60px] h-[60px] rotate-y-180 backface-hidden', {backgroundColor: BLUE})},
  {id: 'selectNone', e: 'same', c: () => T('Ab', {userSelect: 'none'}), f: () => NT('Ab', 'select-none')},
  {id: 'cursorPointer', e: 'same', c: () => B({cursor: 'pointer'}), f: () => N('w-[60px] h-[60px] cursor-pointer', {backgroundColor: BLUE})},
];

const VARIANTS = [
  'ios:bg-red-500', 'android:bg-red-500', 'native:bg-red-500', 'web:bg-red-500',
  'md:bg-red-500', 'xl:bg-red-500', 'max-md:bg-red-500', 'landscape:bg-red-500',
  'portrait:bg-red-500', 'dark:bg-red-500', 'motion-safe:bg-red-500', 'motion-reduce:bg-red-500',
  'ltr:bg-red-500', 'rtl:bg-red-500', 'contrast-more:bg-red-500', '@container',
];
// Literal copies so Tailwind's scanner emits every variant class.
const VARIANT_CLASSES = {
  'ios:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 ios:bg-red-500',
  'android:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 android:bg-red-500',
  'native:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 native:bg-red-500',
  'web:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 web:bg-red-500',
  'md:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 md:bg-red-500',
  'xl:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 xl:bg-red-500',
  'max-md:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 max-md:bg-red-500',
  'landscape:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 landscape:bg-red-500',
  'portrait:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 portrait:bg-red-500',
  'dark:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 dark:bg-red-500',
  'motion-safe:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 motion-safe:bg-red-500',
  'motion-reduce:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 motion-reduce:bg-red-500',
  'ltr:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 ltr:bg-red-500',
  'rtl:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 rtl:bg-red-500',
  'contrast-more:bg-red-500': 'w-[60px] h-[60px] bg-gray-300 contrast-more:bg-red-500',
};

function Container() {
  return (
    <View className="@container w-[60px] h-[60px] bg-gray-300">
      <View className="w-full h-full @[40px]:bg-red-500" />
    </View>
  );
}

const CELL_W = 240, CELL_H = 150, PER_ROW = 5;
function Cell({t, i}) {
  const cx = (i % PER_ROW) * CELL_W, cy = Math.floor(i / PER_ROW) * CELL_H;
  return (
    <View style={{position: 'absolute', left: cx, top: cy, width: CELL_W, height: CELL_H}}>
      <Text style={{position: 'absolute', left: 4, top: 1, fontSize: 10, color: 'rgb(120,120,120)'}}>{(i + 1) + ' ' + t.id}</Text>
      <View style={{position: 'absolute', left: 30, top: 45}}>{t.c()}</View>
      <View style={{position: 'absolute', left: 150, top: 45}}>{t.f()}</View>
    </View>
  );
}

function Interact() {
  // Fixed targets for windowed input: hover box (20,20), press box (120,20),
  // group-hover box (220,20), focus field (20,120).
  return (
    <View style={{flex: 1, backgroundColor: 'white'}}>
      <Pressable className="absolute left-[20px] top-[20px] w-[80px] h-[80px] bg-blue-500 hover:bg-red-500" />
      <Pressable className="absolute left-[120px] top-[20px] w-[80px] h-[80px] bg-blue-500 active:bg-red-500" />
      <Pressable className="group absolute left-[220px] top-[20px] w-[80px] h-[80px] bg-gray-300">
        <View className="w-[40px] h-[40px] bg-blue-500 group-hover:bg-red-500" />
      </Pressable>
      <TextInput className="absolute left-[20px] top-[120px] w-[160px] h-[40px] border-4 border-blue-500 focus:border-red-500" />
      <Pressable className="absolute left-[220px] top-[120px] w-[80px] h-[40px] bg-blue-500 disabled:bg-red-500" disabled />
    </View>
  );
}

function Probe() {
  const [scene, setScene] = React.useState(null);
  React.useEffect(() => {
    Linking.getInitialURL().then((u) => setScene((u || 'probe://nw').replace('probe://', ''))).catch(() => setScene('nw'));
  }, []);
  if (scene === null) return <View style={{flex: 1, backgroundColor: 'white'}} />;
  if (scene === 'interact') return <Interact />;
  if (scene === 'variants') {
    const tiles = VARIANTS.map((v) => ({
      id: v,
      c: () => <View style={{width: 60, height: 60, backgroundColor: 'rgb(209,213,220)'}} />,
      f: () => (v === '@container' ? <Container /> : <View className={VARIANT_CLASSES[v]} />),
    }));
    return <View style={{flex: 1, backgroundColor: 'white'}}>{tiles.map((t, i) => <Cell key={t.id} t={t} i={i} />)}</View>;
  }
  return <View style={{flex: 1, backgroundColor: 'white'}}>{TESTS.map((t, i) => <Cell key={t.id} t={t} i={i} />)}</View>;
}

AppRegistry.registerComponent('Eng19NativeWind', () => Probe);
