/**
 * iOS M1 fixture (iOS host phase, Task 3.2): the smallest React tree whose
 * pixels prove the iOS engine renders a bundle. Modeled on fixtures/p2-mount:
 * plain, rounded and nested boxes at fixed positions, plus one text label.
 * Only react/react-native core; geometry in geometry.js.
 */
import React from 'react';
import {AppRegistry, Text, View} from 'react-native';

const geometry = require('./geometry');

const {background, boxes, label} = geometry;

function Box({box}) {
  return (
    <View
      style={{
        position: 'absolute',
        left: box.x,
        top: box.y,
        width: box.width,
        height: box.height,
        backgroundColor: box.color,
        borderRadius: box.radius || 0,
      }}>
      {box.child ? <Box box={box.child} /> : null}
    </View>
  );
}

function IosSmoke() {
  return (
    <View style={{flex: 1, backgroundColor: background}}>
      {boxes.map(box => (
        <Box key={box.id} box={box} />
      ))}
      <Text
        style={{
          position: 'absolute',
          left: label.x,
          top: label.y,
          fontSize: label.fontSize,
          color: label.color,
        }}>
        {label.text}
      </Text>
    </View>
  );
}

AppRegistry.registerComponent('IosSmoke', () => IosSmoke);
