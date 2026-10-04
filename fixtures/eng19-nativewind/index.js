/**
 * ENG-19 fixture: a scratch app with NO app-level Metro shims bundles and
 * paints a NativeWind className box on the impeller platform.
 *
 * The app's metro.config.js is ONLY withImpeller + withNativewind (see
 * metro.config.js next to this file). Before ENG-19 the bundle needed three
 * app-side shims (HostApp: Image.impeller-stub.js, reanimated-stub.js,
 * PlatformColorValueTypes in a self re-export list). The package now ships
 * all three.
 *
 * Paints: a 200 x 100 bg-red-500 box at (20, 20) on a white page, a
 * bg-blue-600 box at (20, 140) through react-native-css's Animated path
 * (transition-* utilities make useNativeCss reach animatedComponentFamily,
 * which require()s react-native-reanimated), and an <Image> placeholder.
 */
import './global.css';
import React from 'react';
import {AppRegistry, Image, View} from 'react-native';

function Fixture() {
  return (
    <View className="bg-white" style={{width: 320, height: 300}}>
      <View className="absolute left-[20px] top-[20px] h-[100px] w-[200px] bg-red-500" />
      <View className="absolute left-[20px] top-[140px] h-[100px] w-[200px] bg-blue-600 transition-colors duration-200" />
      <Image style={{position: 'absolute', left: 240, top: 20, width: 40, height: 40}} source={{uri: 'about:blank'}} />
    </View>
  );
}

AppRegistry.registerComponent('Eng19NativeWind', () => Fixture);
