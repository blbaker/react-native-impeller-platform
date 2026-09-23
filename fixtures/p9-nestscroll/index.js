/**
 * ENG-02c nested-scroll probe fixture.
 *
 * A vertical <ScrollView> (the inner LIST) sits inside the left panel of a
 * horizontal <ScrollView> (the outer ROW). The two overflow on DIFFERENT axes:
 *
 *   - OUTER row: two 300pt panels laid out in a row inside a 300pt viewport, so
 *     contentWidth 600, scrollable range 300, overflows X only. Right panel is
 *     solid GREEN so a horizontal scroll is unmistakable by pixel.
 *   - INNER list: four 100pt rows in a 200pt viewport, so contentHeight 400,
 *     scrollable range 200, overflows Y only. Rows are red/blue/yellow/magenta.
 *
 * The discriminator the gate drives at the SAME point (150,100):
 *   dx  -> the wheel axis is X, the inner list does not overflow X, so the walk
 *          skips it and moves the OUTER row: green slides in, the inner list's
 *          own offset never changes.
 *   dy  -> the wheel axis is Y, the inner list overflows Y, so it is the nearest
 *          axis-matching ancestor and IT moves: the outer row stays at 0 (no
 *          green appears) and the visible inner row changes.
 *
 * Off Android RN sends horizontal={false} for the outer <ScrollView horizontal>,
 * so the outer being scrollable at all is the content-overflow axis derivation
 * (ENG-02b) still working; the axis-FIRST resolution is ENG-02c on top of it.
 */
import React from 'react';
import {Alert, AppRegistry, ScrollView, Text, View} from 'react-native';

export const ROW_H = 100;
export const ROWS = [
  {id: 'r0', color: '#ff0000'}, // red
  {id: 'r1', color: '#0000ff'}, // blue
  {id: 'r2', color: '#ffff00'}, // yellow
  {id: 'r3', color: '#ff00ff'}, // magenta
];

function InnerList() {
  return (
    <ScrollView
      style={{width: 300, height: 200}}
      scrollEventThrottle={1}
      onScroll={e => {
        const y = e?.nativeEvent?.contentOffset?.y;
        Alert.alert('inner', String(y));
      }}>
      {ROWS.map(r => (
        <View
          key={r.id}
          style={{width: 300, height: ROW_H, backgroundColor: r.color}}>
          <Text style={{color: '#000000', fontSize: 16}}>{r.id}</Text>
        </View>
      ))}
    </ScrollView>
  );
}

function Fixture() {
  return (
    <View style={{width: 300, height: 200, backgroundColor: '#111111'}}>
      <ScrollView
        horizontal
        style={{width: 300, height: 200}}
        scrollEventThrottle={1}
        onScroll={e => {
          const x = e?.nativeEvent?.contentOffset?.x;
          Alert.alert('outer', String(x));
        }}>
        <View style={{width: 300, height: 200}}>
          <InnerList />
        </View>
        <View style={{width: 300, height: 200, backgroundColor: '#00ff00'}}>
          <Text style={{color: '#000000', fontSize: 16}}>green</Text>
        </View>
      </ScrollView>
    </View>
  );
}

AppRegistry.registerComponent('P9NestScroll', () => Fixture);
