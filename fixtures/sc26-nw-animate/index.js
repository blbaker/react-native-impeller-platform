/**
 * SC-26 fixture: NativeWind animate-* / transition-* and the Reanimated API,
 * played by the package's reanimated stub on the JS thread (no
 * react-native-reanimated installed; gate: tools/ci-nw-animate.sh).
 *
 * Row A (y 20): CSS keyframes frozen with play-state paused and a negative
 *   delay, so every capture is deterministic: control square, animate-spin at
 *   -125 ms (45 deg), animate-pulse at -1 s (opacity 0.5), animate-spin running.
 * Row B (y 120): transition-colors red -> blue over 60 s linear, flipped at
 *   mount; animate-bounce and animate-ping running (look only).
 * Row C (y 230 + 22 k): 16 px blue boxes driven by shared values, all started
 *   in the same mount effect, x = 20 + translateX:
 *   0 ref     withTiming 0 -> 1 (60 s linear) via useDerivedValue * 200
 *   1 seq     withSequence(withTiming 200 in 1 s, withTiming 0 in 60 s)
 *   2 repeat  withRepeat(withTiming 200 in 12 s, -1, reverse)
 *   3 delay   withDelay(10 s, withTiming 200 in 60 s)
 *   4 spring  withSpring 200, mass 1 stiffness 0.00704 damping 0.1678 (critical)
 *   5 inline  60 px box, useAnimatedStyle opacity withTiming 1 -> 0.2 in 60 s
 * Headless captures land ~20 s after mount; the gate reads the elapsed time
 * off the ref box and predicts every other tile from it.
 */
import './global.css';
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Animated, {
  Easing,
  useAnimatedStyle,
  useDerivedValue,
  useSharedValue,
  withDelay,
  withRepeat,
  withSequence,
  withSpring,
  withTiming,
} from 'react-native-reanimated';

const linear = (ms) => ({duration: ms, easing: Easing.linear});
const box = (k) => ({position: 'absolute', left: 20, top: 230 + 22 * k, width: 16, height: 16, backgroundColor: '#0000ff'});

function Mover({k, sv}) {
  const st = useAnimatedStyle(() => ({transform: [{translateX: sv.value}]}));
  return <Animated.View style={[box(k), st]} />;
}

function Fixture() {
  const [on, setOn] = React.useState(false);
  const p = useSharedValue(0);
  const ref = useDerivedValue(() => p.value * 200);
  const seq = useSharedValue(0);
  const rep = useSharedValue(0);
  const del = useSharedValue(0);
  const spr = useSharedValue(0);
  const fade = useAnimatedStyle(() => ({opacity: withTiming(on ? 0.2 : 1, linear(60000))}), [on]);
  React.useEffect(() => {
    setOn(true);
    p.value = withTiming(1, linear(60000));
    seq.value = withSequence(withTiming(200, linear(1000)), withTiming(0, linear(60000)));
    rep.value = withRepeat(withTiming(200, linear(12000)), -1, true);
    del.value = withDelay(10000, withTiming(200, linear(60000)));
    spr.value = withSpring(200, {mass: 1, stiffness: 0.00704, damping: 0.1678});
  }, [p, seq, rep, del, spr]);
  return (
    <View className="bg-white" style={{width: 420, height: 370}}>
      <View className="absolute left-[20px] top-[20px] h-[60px] w-[60px] bg-red-500" />
      <View className="absolute left-[120px] top-[20px] h-[60px] w-[60px] bg-red-500 animate-spin [animation-play-state:paused] [animation-delay:-0.125s]" />
      <View className="absolute left-[220px] top-[20px] h-[60px] w-[60px] bg-red-500 animate-pulse [animation-play-state:paused] [animation-delay:-1s]" />
      <View className="absolute left-[320px] top-[20px] h-[60px] w-[60px] bg-red-500 animate-spin" />
      <View className={`absolute left-[20px] top-[120px] h-[60px] w-[60px] transition-colors duration-[60000ms] ease-linear ${on ? 'bg-blue-500' : 'bg-red-500'}`} />
      <View className="absolute left-[220px] top-[120px] h-[60px] w-[60px] bg-red-500 animate-bounce" />
      <View className="absolute left-[320px] top-[120px] h-[60px] w-[60px] bg-red-500 animate-ping" />
      <Mover k={0} sv={ref} />
      <Mover k={1} sv={seq} />
      <Mover k={2} sv={rep} />
      <Mover k={3} sv={del} />
      <Mover k={4} sv={spr} />
      <Animated.View style={[box(5), {width: 60}, fade]} />
    </View>
  );
}

AppRegistry.registerComponent('Sc26NwAnimate', () => Fixture);
