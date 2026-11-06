/**
 * Touch drag-to-scroll fixture (RK3588 board: one finger on a touchscreen).
 *
 *   vertical ScrollView   x 0..300    y 0..600    30 Pressable rows, 100 pt
 *   horizontal pager      x 350..950  y 50..350   4 pages of 600, pagingEnabled
 *   PanResponder strip    x 350..950  y 400..500  (not inside a ScrollView)
 *
 * Every outcome is one [js] line; tools/ci-touch-scroll.sh reads them.
 */
import React from 'react';
import {AppRegistry, PanResponder, Pressable, ScrollView, Text, View} from 'react-native';

const r = (n) => Math.round(n);
const at = (e) => e.nativeEvent.contentOffset;

function Rows() {
  return Array.from({length: 30}, (_, i) => (
    <Pressable
      key={i}
      onPress={() => console.log('ROW_PRESS ' + i)}
      style={{height: 100, backgroundColor: i % 2 ? '#222222' : '#333333'}}>
      <Text style={{color: '#ffffff', fontSize: 24}}>{'row ' + i}</Text>
    </Pressable>
  ));
}

const pan = PanResponder.create({
  onStartShouldSetPanResponder: () => true,
  onMoveShouldSetPanResponder: () => true,
  onPanResponderGrant: () => console.log('PAN_GRANT'),
  onPanResponderTerminate: () => console.log('PAN_TERMINATE'),
  onPanResponderRelease: (_e, g) => console.log('PAN_RELEASE dx=' + r(g.dx) + ' dy=' + r(g.dy)),
});

let vMoves = 0;

function Fixture() {
  return (
    <View collapsable={false} style={{width: 1000, height: 700, backgroundColor: '#000000'}}>
      <ScrollView
        style={{position: 'absolute', left: 0, top: 0, width: 300, height: 600}}
        scrollEventThrottle={16}
        onScroll={(e) => console.log('V_SCROLL y=' + r(at(e).y))}
        onScrollBeginDrag={(e) => console.log('V_BEGIN_DRAG y=' + r(at(e).y))}
        onScrollEndDrag={(e) => console.log('V_END_DRAG y=' + r(at(e).y))}
        onMomentumScrollBegin={(e) => console.log('V_MOMENTUM_BEGIN y=' + r(at(e).y))}
        onMomentumScrollEnd={(e) => console.log('V_MOMENTUM_END y=' + r(at(e).y))}
        onTouchStart={() => console.log('V_TOUCH_START')}
        onTouchMove={() => {
          vMoves += 1;
        }}
        onTouchCancel={() => console.log('V_TOUCH_CANCEL moves=' + vMoves)}
        onTouchEnd={() => console.log('V_TOUCH_END moves=' + vMoves)}>
        <Rows />
      </ScrollView>
      <ScrollView
        horizontal
        pagingEnabled
        style={{position: 'absolute', left: 350, top: 50, width: 600, height: 300}}
        scrollEventThrottle={16}
        onScroll={(e) => console.log('H_SCROLL x=' + r(at(e).x))}
        onScrollBeginDrag={(e) => console.log('H_BEGIN_DRAG x=' + r(at(e).x))}
        onScrollEndDrag={(e) => console.log('H_END_DRAG x=' + r(at(e).x))}
        onMomentumScrollBegin={(e) => console.log('H_MOMENTUM_BEGIN x=' + r(at(e).x))}
        onMomentumScrollEnd={(e) => console.log('H_MOMENTUM_END x=' + r(at(e).x))}>
        {['#c0392b', '#27ae60', '#2980b9', '#f39c12'].map((c, i) => (
          <View key={c} style={{width: 600, height: 300, backgroundColor: c}}>
            <Text style={{color: '#ffffff', fontSize: 32}}>{'page ' + i}</Text>
          </View>
        ))}
      </ScrollView>
      <View
        {...pan.panHandlers}
        style={{position: 'absolute', left: 350, top: 400, width: 600, height: 100, backgroundColor: '#8e44ad'}}>
        <Text style={{color: '#ffffff', fontSize: 24}}>pan strip</Text>
      </View>
    </View>
  );
}

AppRegistry.registerComponent('TouchScrollFixture', () => Fixture);
