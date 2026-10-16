// FP-34 fixture (tools/ci-prewarm.sh). 400x300. A cheap moving square repaints every frame. When the
// rAF counter reaches FIRST_ON (30) the tree gains, in ONE commit, the first use of every class the
// pre-warm tour covers: all 16 mixBlendMode values, rect / rounded / oval clips, an opacity
// save-layer, a content blur, a color-matrix filter, linear and radial gradients, box shadows (mask
// blur) and bold / italic / underlined / clamped text. The gate reads the cold frames before this
// scene mounts (a pipeline nobody warmed stalls them) and the frame that first paints it.
import React, {useEffect, useState} from 'react';
import {AppRegistry, Text, View} from 'react-native';

// rAF ticks run far faster than frames here (hundreds per frame), so the tree gains the features
// within the first few frames, not at frame 30.
const FIRST_ON = 30;
// Much later, the root colour changes (a full repaint of the same scene) and one extra node mounts,
// so the gate can find that frame by its node count and compare it with the first-use frame.
const LATE_MS = 700;
const MODES = ['normal', 'multiply', 'screen', 'overlay', 'darken', 'lighten', 'color-dodge',
  'color-burn', 'hard-light', 'soft-light', 'difference', 'exclusion', 'hue', 'saturation', 'color',
  'luminosity'];
const abs = (left, top, width, height, extra) => ({position: 'absolute', left, top, width, height, ...extra});

// Every box is small: the full repaint that first paints them stays cheap, so a pipeline compile
// (tens of ms) is the only thing that can make that frame slow.
function Features() {
  return (
    <>
      {MODES.map((m, i) => (
        <View key={m} style={abs(4 + (i % 8) * 24, 40 + Math.floor(i / 8) * 16, 20, 12,
                                 {backgroundColor: '#e07020', mixBlendMode: m})} />
      ))}
      <View style={abs(4, 76, 24, 16, {backgroundColor: '#2060c0', overflow: 'hidden'})}>
        <View style={abs(6, 6, 30, 20, {backgroundColor: '#ffffff'})} />
      </View>
      <View style={abs(34, 76, 24, 16, {backgroundColor: '#2060c0', overflow: 'hidden', borderRadius: 7})}>
        <View style={abs(6, 6, 30, 20, {backgroundColor: '#ffffff'})} />
      </View>
      <View style={abs(64, 76, 24, 16, {backgroundColor: '#2060c0', overflow: 'hidden', borderRadius: '50%'})}>
        <View style={abs(6, 6, 30, 20, {backgroundColor: '#ffffff'})} />
      </View>
      <View style={abs(94, 76, 24, 16, {opacity: 0.5})}>
        <View style={abs(0, 0, 16, 10, {backgroundColor: '#c02020'})} />
        <View style={abs(8, 6, 16, 10, {backgroundColor: '#20c020'})} />
      </View>
      <View style={abs(124, 76, 24, 16, {backgroundColor: '#c02020', filter: 'blur(2px)'})} />
      <View style={abs(154, 76, 24, 16, {backgroundColor: '#c02020', filter: 'grayscale(1)'})} />
      <View style={abs(4, 100, 30, 16, {experimental_backgroundImage: 'linear-gradient(to right, rgb(255,0,0), rgb(0,0,255))'})} />
      <View style={abs(40, 100, 30, 16, {experimental_backgroundImage: 'radial-gradient(rgb(255,0,0), rgb(0,0,255))'})} />
      <View style={abs(76, 100, 24, 16, {backgroundColor: '#ffffff', boxShadow: '2px 2px 4px rgba(0,0,0,0.6)'})} />
      <View style={abs(106, 100, 24, 16, {backgroundColor: '#ffffff', borderRadius: 6, boxShadow: '0px 3px 5px rgba(0,0,0,0.5)'})} />
      <Text style={abs(4, 124, 50, 12, {fontSize: 9, fontWeight: 'bold', color: '#101010'})}>Bold</Text>
      <Text style={abs(40, 124, 50, 12, {fontSize: 9, fontStyle: 'italic', color: '#101010'})}>Italic</Text>
      <Text style={abs(76, 124, 50, 12, {fontSize: 9, textDecorationLine: 'underline', color: '#101010'})}>Under</Text>
      <Text numberOfLines={1} style={abs(112, 124, 30, 12, {fontSize: 9, color: '#101010', backgroundColor: '#ffff80'})}>Clamped label that is too long</Text>
      <Text style={abs(150, 124, 40, 12, {fontSize: 9, color: '#101010', textShadowColor: 'rgba(0,0,0,0.5)', textShadowOffset: {width: 1, height: 1}, textShadowRadius: 1})}>Shadow</Text>
    </>
  );
}

function Prewarm() {
  const [n, setN] = useState(0);
  const [late, setLate] = useState(false);
  useEffect(() => {
    const t = setTimeout(() => setLate(true), LATE_MS);
    return () => clearTimeout(t);
  }, []);
  useEffect(() => {
    let id;
    const tick = () => {
      setN(v => v + 1);
      id = requestAnimationFrame(tick);
    };
    id = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(id);
  }, []);
  return (
    <View style={{flex: 1, backgroundColor: late ? '#80c0a0' : '#80a0c0'}}>
      {late ? <View style={abs(396, 296, 2, 2, {backgroundColor: '#000000'})} /> : null}
      <View style={abs(4 + (n % 60) * 4, 4, 24, 24, {backgroundColor: '#202020'})} />
      {n >= FIRST_ON ? <Features /> : null}
    </View>
  );
}

AppRegistry.registerComponent('Fp34Prewarm', () => Prewarm);
