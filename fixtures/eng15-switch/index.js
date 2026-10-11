/**
 * ENG-15 fixture: <Switch> mounts, paints and takes presses.
 *
 * White page, five switches (iOS 51 x 31 each), wrapped in absolutely placed
 * Views so their positions are fixed:
 *   S1 (20, 20)   controlled: onValueChange sets state     -> a tap turns it ON
 *   S2 (20, 80)   refusing: value stays false               -> a tap snaps back OFF
 *   S3 (20,140)   disabled, value true                      -> a tap does nothing
 *   S4 (20,200)   value true,  trackColor {false: blue, true: magenta}, thumb yellow
 *   S5 (120,200)  value false, same colours
 * Logs `ENG15 s1 change=<v>`, `ENG15 s2 change=<v>`, `ENG15 s3 change=<v>`.
 * The gate is tools/ci-switch.sh.
 */
import React from 'react';
import {AppRegistry, Switch, View} from 'react-native';

const CUSTOM = {trackColor: {false: '#0000ff', true: '#ff00ff'}, thumbColor: '#ffff00'};

function At({left, top, children}) {
  return <View style={{position: 'absolute', left, top}}>{children}</View>;
}

function Fixture() {
  const [s1, setS1] = React.useState(false);
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#ffffff'}}>
      <At left={20} top={20}>
        <Switch
          value={s1}
          onValueChange={v => {
            console.log(`ENG15 s1 change=${v}`);
            setS1(v);
          }}
        />
      </At>
      <At left={20} top={80}>
        <Switch value={false} onValueChange={v => console.log(`ENG15 s2 change=${v}`)} />
      </At>
      <At left={20} top={140}>
        <Switch value disabled onValueChange={v => console.log(`ENG15 s3 change=${v}`)} />
      </At>
      <At left={20} top={200}>
        <Switch value {...CUSTOM} />
      </At>
      <At left={120} top={200}>
        <Switch value={false} {...CUSTOM} />
      </At>
    </View>
  );
}

AppRegistry.registerComponent('Eng15Switch', () => Fixture);
