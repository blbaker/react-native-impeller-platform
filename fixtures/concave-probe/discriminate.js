/**
 * CONCAVE-FILL DISCRIMINATOR (internal request).
 *
 * The concave cases paint their full 80x80 BOX (6400), not the convex hull.
 * Three things could do that, and they need separate arms:
 *
 *   row 1  fillRule default (nonzero)  — the reported case
 *   row 2  fillRule="evenodd"          — is it nonzero-specific?
 *   row 3  the same concave outlines drawn as STROKE only — stroke is
 *          reported unaffected, so this is the control that says the
 *          GEOMETRY reaching the builder is right and only FILL is wrong.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Path} from 'react-native-svg';

const MARK = 'rgb(0, 255, 0)';

const L = 'M10 10 L90 10 L90 50 L50 50 L50 90 L10 90 Z';
const ARROW = 'M10 10 L90 10 L90 90 L50 50 L10 90 Z';

function cell(child, key) {
  return (
    <Svg key={key} width={100} height={100} viewBox="0 0 100 100">
      {child}
    </Svg>
  );
}

function Fixture() {
  return (
    <View style={{width: 700, height: 400, backgroundColor: 'rgb(0, 0, 0)'}}>
      <View style={{flexDirection: 'row', gap: 20, padding: 20}}>
        {cell(<Path d={L} fill={MARK} />, 1)}
        {cell(<Path d={ARROW} fill={MARK} />, 2)}
        {cell(<Path d={L} fill={MARK} fillRule="evenodd" />, 3)}
        {cell(<Path d={ARROW} fill={MARK} fillRule="evenodd" />, 4)}
        {cell(
          <Path d={L} fill="none" stroke={MARK} strokeWidth={4} />,
          5,
        )}
      </View>
    </View>
  );
}

AppRegistry.registerComponent('ConcaveProbe', () => Fixture);
