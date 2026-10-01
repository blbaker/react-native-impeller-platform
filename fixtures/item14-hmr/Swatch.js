import React from 'react';
import {View} from 'react-native';

// The gate rewrites this colour while the app runs (Fast Refresh arm).
const COLOR = '#ff0000';

export default function Swatch() {
  console.log('SWATCH_RENDER ' + COLOR);
  return (
    <View
      style={{
        position: 'absolute',
        left: 50,
        top: 50,
        width: 100,
        height: 100,
        backgroundColor: COLOR,
      }}
    />
  );
}
