// FP-41 fixture: expo-blur <BlurView> over a high-frequency backdrop.
// 400x300. Vertical 4 px stripes (red / blue) fill the window. Geometry the gate reads:
//   Blur     (40,40) 140x100, tint dark, intensity 60, with a crisp 20x20 green child at (100,80).
//   Control  (220,40) 140x100, a plain View painted the SAME dark tint colour, no blur.
//   Scroll   ScrollView (40,170) 320x110 at contentOffset y=60; its content is 330 tall of
//            stripes with a light BlurView at content (20,80) 120x60, so on screen (60,190) 120x60.
// Fp41Backdrop = all of it; Fp41NoBlur = the same tree with every BlurView removed (the
// "outside is unchanged" reference).
import React from 'react';
import {AppRegistry, ScrollView, View} from 'react-native';
import {BlurView} from 'expo-blur';

const W = 400, H = 300, STRIPE = 4;
const RED = '#e02020', BLUE = '#2040e0';

function Stripes({width, height}) {
  const cols = [];
  for (let x = 0; x < width; x += STRIPE) {
    cols.push(
      <View key={x} style={{position: 'absolute', left: x, top: 0, width: STRIPE, height,
                            backgroundColor: (x / STRIPE) % 2 ? BLUE : RED}} />,
    );
  }
  return <View style={{position: 'absolute', left: 0, top: 0, width, height}}>{cols}</View>;
}

function Scene({blur}) {
  return (
    <View style={{width: W, height: H, backgroundColor: '#000'}}>
      <Stripes width={W} height={H} />
      {blur ? (
        <BlurView tint="dark" intensity={60}
                  style={{position: 'absolute', left: 40, top: 40, width: 140, height: 100}}>
          <View style={{position: 'absolute', left: 60, top: 40, width: 20, height: 20,
                        backgroundColor: '#00ff00'}} />
        </BlurView>
      ) : null}
      {/* expo-blur getBackgroundColor('dark', 60) = rgba(25,25,25,0.468) */}
      <View style={{position: 'absolute', left: 220, top: 40, width: 140, height: 100,
                    backgroundColor: 'rgba(25,25,25,0.468)'}} />
      <ScrollView style={{position: 'absolute', left: 40, top: 170, width: 320, height: 110}}
                  contentOffset={{x: 0, y: 60}}>
        <View style={{width: 320, height: 330}}>
          <Stripes width={320} height={330} />
          {blur ? (
            <BlurView tint="light" intensity={80}
                      style={{position: 'absolute', left: 20, top: 80, width: 120, height: 60}} />
          ) : null}
        </View>
      </ScrollView>
    </View>
  );
}

AppRegistry.registerComponent('Fp41Backdrop', () => () => <Scene blur />);
AppRegistry.registerComponent('Fp41NoBlur', () => () => <Scene blur={false} />);
