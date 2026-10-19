/**
 * `transparent` must paint nothing, not fall back to a default colour.
 *
 * React Native's cxx platform packed `transparent` (rgba(0,0,0,0)) to 0, which
 * is also its "no colour set" value, so every colour prop below took its unset
 * fallback: black borders, outlines and shadows, black or inherited text, a
 * grey switch track and placeholder, and a gradient stop read as a colour hint.
 *
 * 500x500 surface on #33cc66, 25 cells of 100x100. Cell (c, r) has its origin
 * at (100c, 100r). tools/transparent-color-judge.py reads one probe per cell:
 * a feature cell must show the background where the transparent colour is, and
 * a CONTROL cell paints the same thing in a real colour so a blind probe fails.
 * Row 4, columns 2-4 stay empty: the judge reads them as the background.
 *
 * Logs `TC stale-text color=transparent` once the red -> transparent text
 * (cell K) has re-rendered.
 */
import React, {useEffect, useState} from 'react';
import {AppRegistry, Switch, Text, TextInput, View} from 'react-native';

const BG = '#33cc66';
const RED = '#ff0000';
const at = (c, r, dx = 0, dy = 0) => ({position: 'absolute', left: 100 * c + dx, top: 100 * r + dy});
const box = {width: 40, height: 40, backgroundColor: '#ffffff'};
const spaces = '\u00a0\u00a0\u00a0\u00a0';

function StaleText() {
  const [color, setColor] = useState(RED);
  useEffect(() => {
    const t = setTimeout(() => setColor('transparent'), 50);
    return () => clearTimeout(t);
  }, []);
  useEffect(() => {
    if (color === 'transparent') console.log('TC stale-text color=transparent');
  }, [color]);
  return <Text style={[at(3, 1, 10, 10), {fontSize: 40, color}]}>MM</Text>;
}

const triangle = edge => ({
  width: 0, height: 0,
  borderBottomWidth: 60, borderBottomColor: RED,
  borderRightWidth: 60, borderRightColor: edge,
});
const gradient = mid => `linear-gradient(to right, #ff0000 0%, ${mid} 50%, #0000ff 100%)`;

function TransparentColor() {
  return (
    <View style={{flex: 1, backgroundColor: BG}}>
      {/* row 0: borders, outline, shadows */}
      <View style={[at(0, 0, 10, 10), triangle('transparent')]} />
      <View style={[at(1, 0, 30, 30), box, {outlineWidth: 10, outlineStyle: 'solid', outlineColor: 'transparent'}]} />
      <View style={[at(2, 0, 20, 20), box, {shadowColor: 'transparent', shadowOpacity: 1, shadowRadius: 0, shadowOffset: {width: 20, height: 20}}]} />
      <View style={[at(3, 0, 20, 20), box, {boxShadow: [{offsetX: 20, offsetY: 20, blurRadius: 0, color: 'transparent'}]}]} />
      <View style={[at(4, 0, 20, 20), box, {boxShadow: [{offsetX: 20, offsetY: 20, blurRadius: 0, color: RED}]}]} />

      {/* row 1: text colour, nested text, text shadow, a colour change, control */}
      <Text style={[at(0, 1, 10, 10), {fontSize: 40, color: 'transparent'}]}>MM</Text>
      <Text style={[at(1, 1, 10, 10), {fontSize: 40, color: RED}]}>
        <Text style={{color: 'transparent'}}>MM</Text>
      </Text>
      <Text style={[at(2, 1, 10, 10), {fontSize: 40, color: BG, textShadowColor: 'transparent', textShadowOffset: {width: 6, height: 6}, textShadowRadius: 0.1}]}>MM</Text>
      <StaleText />
      <Text style={[at(4, 1, 10, 10), {fontSize: 40, color: RED}]}>MM</Text>

      {/* row 2: underline colour, drop-shadow filter, gradient stop */}
      <Text style={[at(0, 2, 10, 10), {fontSize: 40, color: '#0000ff', textDecorationLine: 'underline', textDecorationColor: 'transparent'}]}>{spaces}</Text>
      <Text style={[at(1, 2, 10, 10), {fontSize: 40, color: '#0000ff', textDecorationLine: 'underline', textDecorationColor: RED}]}>{spaces}</Text>
      <View style={[at(2, 2, 20, 20), box, {filter: [{dropShadow: {offsetX: 20, offsetY: 20, standardDeviation: 0, color: 'transparent'}}]}]} />
      <View style={[at(3, 2, 20, 20), box, {filter: [{dropShadow: {offsetX: 20, offsetY: 20, standardDeviation: 0, color: RED}}]}]} />
      <View style={[at(4, 2, 0, 10), {width: 100, height: 80, experimental_backgroundImage: gradient('transparent')}]} />

      {/* row 3: gradient control, switch track, placeholder */}
      <View style={[at(0, 3, 0, 10), {width: 100, height: 80, experimental_backgroundImage: gradient('rgba(0,0,255,0)')}]} />
      <Switch style={at(1, 3, 20, 20)} value={false} trackColor={{false: 'transparent', true: RED}} thumbColor="#ffffff" />
      <Switch style={at(2, 3, 20, 20)} value={false} trackColor={{false: RED, true: RED}} thumbColor="#ffffff" />
      <TextInput style={[at(3, 3, 10, 20), {width: 80, height: 60, fontSize: 30, padding: 0}]} placeholder="MM" placeholderTextColor="transparent" />
      <TextInput style={[at(4, 3, 10, 20), {width: 80, height: 60, fontSize: 30, padding: 0}]} placeholder="MM" placeholderTextColor={RED} />

      {/* row 4: a transparent END stop (already right before the fix), red box */}
      <View style={[at(0, 4, 10, 10), {width: 80, height: 80, experimental_backgroundImage: 'linear-gradient(to right, #ff0000, transparent)'}]} />
      <View style={[at(1, 4, 20, 20), {width: 40, height: 40, backgroundColor: RED}]} />
    </View>
  );
}

AppRegistry.registerComponent('TransparentColor', () => TransparentColor);
