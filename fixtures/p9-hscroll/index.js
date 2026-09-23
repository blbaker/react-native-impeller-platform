/**
 * ENG-02b horizontal scroll probe fixture.
 *
 * A `<ScrollView horizontal>` whose content lays out in a ROW wider than the
 * viewport. Off Android, RN sends horizontal={false} to native (see
 * SceneGraph::scrollBy axis note), so the ONLY thing that makes this scrollable
 * is the content-overflow axis derivation. Six 100pt-wide columns in a 300pt
 * viewport: contentWidth 600, scrollable range exactly 300, one notch 40pt.
 */
import React from 'react';
import {Alert, AppRegistry, ScrollView, Text, View} from 'react-native';

export const COL_W = 100;
export const COLS = [
  {id: 'c0', color: '#ff0000'},
  {id: 'c1', color: '#00ff00'},
  {id: 'c2', color: '#0000ff'},
  {id: 'c3', color: '#ffff00'},
  {id: 'c4', color: '#ff00ff'},
  {id: 'c5', color: '#00ffff'},
];

function Fixture() {
  return (
    <View style={{width: 300, height: 200, backgroundColor: '#111111'}}>
      <ScrollView
        horizontal
        style={{width: 300, height: 200}}
        scrollEventThrottle={1}
        onScroll={e => {
          const x = e?.nativeEvent?.contentOffset?.x;
          Alert.alert('scrolled', String(x));
        }}>
        {COLS.map(c => (
          <View
            key={c.id}
            style={{width: COL_W, height: 200, backgroundColor: c.color}}>
            <Text style={{color: '#000000', fontSize: 16}}>{c.id}</Text>
          </View>
        ))}
      </ScrollView>
    </View>
  );
}

AppRegistry.registerComponent('P9HScroll', () => Fixture);
