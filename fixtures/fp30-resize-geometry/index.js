/**
 * FP-30 fixture for tools/ci-resize-geometry.sh (windowed, --scale 1).
 * ResizeGeometry: a 100x100 pt pure-red reference square, centred by flex in a
 * black root that fills the window, so every relayout moves it and only a
 * frame stretched onto a window of another size changes its displayed aspect.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';

function ResizeGeometry() {
  return (
    <View style={{flex: 1, backgroundColor: '#000000', alignItems: 'center', justifyContent: 'center'}}>
      <View style={{width: 100, height: 100, backgroundColor: '#ff0000'}} />
    </View>
  );
}

AppRegistry.registerComponent('ResizeGeometry', () => ResizeGeometry);
