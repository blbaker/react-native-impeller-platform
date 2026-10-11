/**
 * ENG-09 world-raster gate — PATH-DECOMPOSITION REFERENCE.
 *
 * The CURRENT (pre-<world>) way to put an externally-computed raster on
 * screen: decompose it into one filled RNSVGPath rect per tile. 238 paths
 * (17 x 14, matching fixtures/eng09-world-raster/pattern.js), each filled
 * with the SAME grayscale level buildPattern() burns into the corresponding
 * pixels of the <world> fixture's RGBA buffer.
 *
 * This is the gate's REFERENCE render, not a demo of a good API -- it is
 * exactly the ~238-RNSVGPath structure ENG-09 exists to replace. The luma
 * histogram of this render is what tools/ci-world-raster.sh diffs the
 * <world>-node render against: same visual content, produced through the
 * OLD, already-proven-correct path (ci-svg.sh / ci-mark.sh's own machinery),
 * so a match is evidence the NEW path (TurboModule -> WorldRasterStore ->
 * GL texture -> DrawTextureRect) reproduces it, not evidence of anything
 * about <world> in isolation.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {Path} from 'react-native-svg';
import {COLS, ROWS, TILE, WIDTH, HEIGHT, levelForTile} from './pattern';

function tileRect(col, row) {
  const x0 = col * TILE;
  const y0 = row * TILE;
  const x1 = x0 + TILE;
  const y1 = y0 + TILE;
  return `M${x0} ${y0} L${x1} ${y0} L${x1} ${y1} L${x0} ${y1} Z`;
}

function toHex2(n) {
  return n.toString(16).padStart(2, '0');
}

function Reference() {
  const tiles = [];
  for (let row = 0; row < ROWS; row++) {
    for (let col = 0; col < COLS; col++) {
      const level = levelForTile(row * COLS + col);
      const hex = toHex2(level);
      tiles.push(
        <Path
          key={`${col}-${row}`}
          d={tileRect(col, row)}
          fill={`#${hex}${hex}${hex}`}
        />,
      );
    }
  }
  return (
    <View style={{width: WIDTH, height: HEIGHT, backgroundColor: '#ffffff'}}>
      <Svg width={WIDTH} height={HEIGHT} viewBox={`0 0 ${WIDTH} ${HEIGHT}`}>
        {tiles}
      </Svg>
    </View>
  );
}

AppRegistry.registerComponent('Eng09WorldReference', () => Reference);
