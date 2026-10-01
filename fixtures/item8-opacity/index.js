/**
 * parity item 8 fixture: a parent's opacity applies to its children.
 *
 * White background. Each case is a 60x60 parent holding a 40x40 red child at
 * (10,10) of the parent:
 *   P0  opacity 0    at (20, 20)   -> child invisible: pixel (50,50) white
 *   P5  opacity 0.5  at (100, 20)  -> child half red: pixel (130,50) ~(255,128,128)
 *   P1  opacity 1    at (180, 20)  -> child solid red: pixel (210,50) (255,0,0)
 *   N   nested: outer 0.5 > inner 0.5 > red child at (260, 20)
 *       -> pixel (290,50) ~ 25% red: (255,191,191)
 *   O   overlap: opacity 0.5 parent with TWO overlapping opaque children
 *       (red then blue) at (20, 100) -> the overlap is HALF BLUE OVER WHITE
 *       (255*0.5 blend of blue), NOT blue-over-red: a group opacity, not a
 *       per-child alpha. Pixel (60,130) where both overlap.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';

const red = {position: 'absolute', left: 10, top: 10, width: 40, height: 40, backgroundColor: '#ff0000'};

function Box({x, y, opacity, children}) {
  return (
    <View style={{position: 'absolute', left: x, top: y, width: 60, height: 60, opacity}}>
      {children}
    </View>
  );
}

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      <Box x={20} y={20} opacity={0}><View style={red} /></Box>
      <Box x={100} y={20} opacity={0.5}><View style={red} /></Box>
      <Box x={180} y={20} opacity={1}><View style={red} /></Box>
      <Box x={260} y={20} opacity={0.5}>
        <View style={{position: 'absolute', left: 0, top: 0, width: 60, height: 60, opacity: 0.5}}>
          <View style={red} />
        </View>
      </Box>
      <Box x={20} y={100} opacity={0.5}>
        <View style={{...red, left: 0, top: 0}} />
        <View style={{...red, left: 30, top: 20, backgroundColor: '#0000ff'}} />
      </Box>
    </View>
  );
}

AppRegistry.registerComponent('Item8Opacity', () => Fixture);
