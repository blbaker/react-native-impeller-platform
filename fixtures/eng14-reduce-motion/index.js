/**
 * ENG-14 fixture: AccessibilityInfo reads through the AccessibilityManager
 * TurboModule. Logs one line per query:
 *   [js] ENG14 reduceMotion=<true|false>    or  ENG14 reduceMotion REJECTED
 *   [js] ENG14 boldText=... reduceTransparency=... screenReader=... grayscale=...
 * and paints the whole surface GREEN when reduce motion reads true, RED when
 * it reads false, BLACK while pending or rejected (the pixel arm).
 */
import React from 'react';
import {AccessibilityInfo, AppRegistry, Text, View} from 'react-native';

function q(name, fn) {
  return fn().then(
    v => console.log(`ENG14 ${name}=${v}`),
    e => console.log(`ENG14 ${name} REJECTED ${e}`),
  );
}

function Fixture() {
  const [rm, setRm] = React.useState('pending');
  React.useEffect(() => {
    AccessibilityInfo.isReduceMotionEnabled().then(
      v => {
        console.log(`ENG14 reduceMotion=${v}`);
        setRm(String(v));
      },
      e => {
        console.log(`ENG14 reduceMotion REJECTED ${e}`);
        setRm('rejected');
      },
    );
    q('boldText', () => AccessibilityInfo.isBoldTextEnabled());
    q('reduceTransparency', () => AccessibilityInfo.isReduceTransparencyEnabled());
    q('screenReader', () => AccessibilityInfo.isScreenReaderEnabled());
    q('grayscale', () => AccessibilityInfo.isGrayscaleEnabled());
    q('invertColors', () => AccessibilityInfo.isInvertColorsEnabled());
  }, []);
  const bg = rm === 'true' ? '#00aa00' : rm === 'false' ? '#aa0000' : '#000000';
  return (
    <View style={{width: 200, height: 120, backgroundColor: bg}}>
      <Text style={{color: '#ffffff', fontSize: 14, margin: 8}}>{`reduceMotion=${rm}`}</Text>
    </View>
  );
}

AppRegistry.registerComponent('Eng14ReduceMotion', () => Fixture);
