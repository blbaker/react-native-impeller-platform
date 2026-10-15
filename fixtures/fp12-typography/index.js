/**
 * FP-12 fixture: measure (JS thread) and paint (main thread) on separate typography contexts.
 * Four static rows (regular, bold, custom font, fallback emoji), absolutely positioned so each
 * <Text> box is exactly its measured width. Each string is bracketed by U+2588 FULL BLOCK, whose
 * ink fills its advance, so the painted ink extent of a row equals the width measure reported.
 * The custom row is mostly 'i': Geist Mono (600/1000 em) is about twice the default face's width.
 * Below them, the same four kinds re-render every 4 ms, so the JS thread measures new paragraphs
 * while the main thread paints the previous commit (the TSan arm of ci-typography-threads.sh).
 */
import React from 'react';
import {AppRegistry, Text, View} from 'react-native';

const B = '█';
const ROWS = [
  {key: 'regular', style: {}, text: `${B}Hamburgefonstiv${B}`},
  {key: 'bold', style: {fontWeight: 'bold'}, text: `${B}Hamburgefonstiv${B}`},
  {key: 'custom', style: {fontFamily: 'Geist Mono'}, text: `${B}iiiiiiiiiiii mono${B}`},
  {key: 'emoji', style: {}, text: `${B}ok \u{1F600}\u{1F389} go${B}`},
];

function Fp12Typography() {
  const [n, setN] = React.useState(0);
  React.useEffect(() => {
    const id = setInterval(() => setN((v) => v + 1), 4);
    return () => clearInterval(id);
  }, []);
  return (
    <View style={{flex: 1, backgroundColor: '#ffffff'}}>
      {ROWS.map((r, i) => (
        <Text
          key={r.key}
          style={[{position: 'absolute', left: 20, top: 10 + 40 * i, fontSize: 20, color: '#000000'}, r.style]}>
          {r.text}
        </Text>
      ))}
      {ROWS.map((r, i) => (
        <Text
          key={`churn-${r.key}`}
          style={[{position: 'absolute', left: 20, top: 180 + 26 * i, fontSize: 14, color: '#202020'}, r.style]}>
          {`${r.text} ${n % 997} ${'x'.repeat(n % 7)}`}
        </Text>
      ))}
    </View>
  );
}

AppRegistry.registerComponent('Fp12Typography', () => Fp12Typography);
