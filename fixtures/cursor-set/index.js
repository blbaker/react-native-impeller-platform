/**
 * SC-21 cursor-set fixture: one 20 px row per RN cursor value, in an order
 * where consecutive rows resolve to different GLFW shapes (the hover log only
 * prints on a change). tools/ci-cursor-set.sh hovers row i at y = 20 * i + 10.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';

export const ROWS = [
  'pointer', 'text', 'crosshair', 'col-resize', 'row-resize', 'nwse-resize',
  'nesw-resize', 'move', 'not-allowed', 'ne-resize', 'e-resize', 'n-resize',
  'cell', 'se-resize', 'w-resize', 's-resize', 'nw-resize', 'sw-resize',
  'ew-resize', 'ns-resize', 'all-scroll', 'no-drop', 'url', 'wait', 'alias',
];

function Fixture() {
  return (
    <View style={{width: 200, height: ROWS.length * 20, backgroundColor: '#111111'}}>
      {ROWS.map((cursor, i) => (
        <View
          key={cursor}
          collapsable={false}
          style={{
            position: 'absolute', left: 0, top: i * 20, width: 200, height: 20,
            backgroundColor: i % 2 ? '#2980b9' : '#27ae60', cursor,
          }}
        />
      ))}
    </View>
  );
}

AppRegistry.registerComponent('probe', () => Fixture);
