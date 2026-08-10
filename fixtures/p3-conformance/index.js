/**
 * P3 conformance fixture — NOT a demo app.
 *
 * Renders straight from fixture.json so the geometry the gate probes and the
 * geometry React lays out are literally the same numbers. Same rule as P2:
 * imports react + react-native core only, nothing from the app template.
 *
 * Each block below targets one prop family the P2 renderer got wrong or did not
 * implement. The comments say what a WRONG renderer looks like, because that is
 * the thing the gate has to be able to see.
 */
import React from 'react';
import {AppRegistry, Text, View} from 'react-native';
import geometry from './fixture.json';

const {surface, edges, corners, gradient, transform, text} = geometry;

function Fixture() {
  return (
    <View
      style={{
        width: surface.width,
        height: surface.height,
        backgroundColor: surface.background,
      }}>
      {/* Per-edge borders. Four DIFFERENT colours on purpose: a renderer that
          resolves the border cascade and then uses one edge for all four paints
          a uniform frame that looks entirely reasonable in a screenshot. */}
      <View
        style={{
          position: 'absolute',
          left: edges.x,
          top: edges.y,
          width: edges.width,
          height: edges.height,
          borderTopWidth: edges.borderWidth,
          borderRightWidth: edges.borderWidth,
          borderBottomWidth: edges.borderWidth,
          borderLeftWidth: edges.borderWidth,
          borderTopColor: edges.top.color,
          borderRightColor: edges.right.color,
          borderBottomColor: edges.bottom.color,
          borderLeftColor: edges.left.color,
        }}
      />

      {/* Exactly ONE rounded corner. */}
      <View
        style={{
          position: 'absolute',
          left: corners.x,
          top: corners.y,
          width: corners.width,
          height: corners.height,
          backgroundColor: corners.color,
          borderTopLeftRadius: corners.topLeftRadius,
        }}
      />

      {/* Linear gradient. Still `experimental_` prefixed in RN 0.86. */}
      <View
        style={{
          position: 'absolute',
          left: gradient.x,
          top: gradient.y,
          width: gradient.width,
          height: gradient.height,
          experimental_backgroundImage: `linear-gradient(to bottom, ${gradient.from}, ${gradient.to})`,
        }}
      />

      {/* Rotation. */}
      <View
        style={{
          position: 'absolute',
          left: transform.x,
          top: transform.y,
          width: transform.width,
          height: transform.height,
          backgroundColor: transform.color,
          transform: [{rotate: `${transform.rotateDeg}deg`}],
        }}
      />

      {/* Same string, same width, one clamped to a single line. The gate
          compares their measured heights instead of trusting either alone. */}
      <View
        style={{
          position: 'absolute',
          left: text.wrapped.x,
          top: text.wrapped.y,
          width: text.boxWidth,
        }}>
        <Text
          testID="wrapped"
          style={{fontSize: text.fontSize, color: '#000000'}}>
          {text.content}
        </Text>
      </View>
      <View
        style={{
          position: 'absolute',
          left: text.clamped.x,
          top: text.clamped.y,
          width: text.boxWidth,
        }}>
        <Text
          testID="clamped"
          numberOfLines={1}
          style={{fontSize: text.fontSize, color: '#000000'}}>
          {text.content}
        </Text>
      </View>
    </View>
  );
}

AppRegistry.registerComponent('P3Fixture', () => Fixture);
