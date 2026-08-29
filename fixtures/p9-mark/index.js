/**
 * P9 acceptance — a HostApp-mark-SHAPED SVG, not the real artwork.
 *
 * The mark itself lives with the macOS tester. What this fixture reproduces is its
 * STRUCTURE, because that is what the engine has to survive:
 *
 *   - many filled paths in one <Svg> (17 here, matching the real count)
 *   - ONE fill colour throughout
 *   - a per-path fill-opacity RAMP -- the grey ramp IS the antialiasing
 *   - nested inside a <G>, as the real mark is
 *
 * If per-path opacity were global, or applied once to the group, every wedge
 * would come out identical and the mark would read as a flat blob. The gate
 * asserts 17 DISTINCT alpha levels, which is a property no single-path test
 * and no "did it paint" check can produce.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import Svg, {G, Path} from 'react-native-svg';

const N = 17;
const CX = 200;
const CY = 150;
const R = 120;

// A ring of wedges. Geometry is deliberately simple -- this fixture is about
// per-path ALPHA, not about arc correctness (arcs are covered by ci-svg.sh's
// parser tier).
function wedge(i) {
  const a0 = (i / N) * Math.PI * 2;
  const a1 = ((i + 1) / N) * Math.PI * 2;
  const x0 = CX + R * Math.cos(a0);
  const y0 = CY + R * Math.sin(a0);
  const x1 = CX + R * Math.cos(a1);
  const y1 = CY + R * Math.sin(a1);
  return `M${CX} ${CY} L${x0.toFixed(2)} ${y0.toFixed(2)} L${x1.toFixed(2)} ${y1.toFixed(2)} Z`;
}

function Mark() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      <Svg width={400} height={300} viewBox="0 0 400 300">
        <G>
          {Array.from({length: N}, (_, i) => (
            <Path
              key={i}
              d={wedge(i)}
              fill="#000000"
              // Ramp from 1/17 to 17/17. Every wedge a different alpha.
              fillOpacity={(i + 1) / N}
            />
          ))}
        </G>
      </Svg>
    </View>
  );
}

AppRegistry.registerComponent('P9Mark', () => Mark);
