/**
 * P2 conformance fixture — NOT a demo app.
 *
 * Every value here is chosen so a pixel probe can assert it, and the geometry is
 * declared once in fixture.json so the gate and the app cannot drift apart.
 *
 * Deliberately imports ONLY react/react-native core. The stock RN template
 * renders NewAppScreen, which drags in StatusBar, Appearance, image assets and
 * more — a failure anywhere in that pile looks identical to "Fabric does not
 * work". This fixture answers exactly one question: does a React tree become
 * pixels.
 */
import React from 'react';
import {AppRegistry, Text, View} from 'react-native';
import geometry from './fixture.json';

const {surface, boxes, label} = geometry;

function Fixture() {
  return (
    <View
      style={{
        width: surface.width,
        height: surface.height,
        backgroundColor: surface.background,
      }}>
      {boxes.map(box => (
        <View
          key={box.id}
          style={{
            position: 'absolute',
            left: box.x,
            top: box.y,
            width: box.width,
            height: box.height,
            backgroundColor: box.color,
            borderRadius: box.radius || 0,
          }}
        />
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

AppRegistry.registerComponent('P2Fixture', () => Fixture);
