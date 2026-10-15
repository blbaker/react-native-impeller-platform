/**
 * FP-40 LayoutAnimation fixture (tools/ci-layout-animation.sh). 400x300 window, white background.
 *   t=700 ms:  red bar A (top 30, left 20, height 40) grows from width 60 to 360    (update arm, row y=50)
 *   t=1500 ms: red box B (top 150, left 100, 200x80) is created                    (create arm, pixel 200,190)
 *   t=2400 ms: box B is deleted                                                     (delete arm)
 * Fp40LayoutAnim calls LayoutAnimation.configureNext(Presets.easeInEaseOut) before each change, Fp40Snap
 * makes the same changes without it (the control: every change must snap in one frame).
 * Each step logs `fp40 step=<name>` so the gate can see the JS side ran.
 */
import React from 'react';
import {AppRegistry, LayoutAnimation, View} from 'react-native';

function makeApp(animate) {
  return function App() {
    const [wide, setWide] = React.useState(false);
    const [showB, setShowB] = React.useState(false);
    React.useEffect(() => {
      const step = (name, fn) => () => {
        if (animate) LayoutAnimation.configureNext(LayoutAnimation.Presets.easeInEaseOut);
        console.log('fp40 step=' + name);
        fn();
      };
      const t = [
        setTimeout(step('update', () => setWide(true)), 700),
        setTimeout(step('create', () => setShowB(true)), 1500),
        setTimeout(step('delete', () => setShowB(false)), 2400),
      ];
      return () => t.forEach(clearTimeout);
    }, []);
    return (
      <View style={{flex: 1, backgroundColor: 'white'}}>
        <View
          style={{position: 'absolute', top: 30, left: 20, height: 40, width: wide ? 360 : 60,
            backgroundColor: 'red'}}
        />
        {showB ? (
          <View
            style={{position: 'absolute', top: 150, left: 100, width: 200, height: 80,
              backgroundColor: 'red'}}
          />
        ) : null}
      </View>
    );
  };
}

AppRegistry.registerComponent('Fp40LayoutAnim', () => makeApp(true));
AppRegistry.registerComponent('Fp40Snap', () => makeApp(false));
