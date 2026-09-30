/**
 * desktop-input-gap P0 item 1 fixture -- FULL keyboard events, not a demo.
 *
 * A focused <TextInput> whose onKeyPress logs to console, wrapped in a
 * <View onKeyDown/onKeyUp> (collapsable={false} so Fabric does not flatten
 * it into its parent and swallow the distinct hit-test/event target --
 * see acceptance-gate-instrument-validation's "fixture routes the probe
 * AROUND the branch under test" pitfall). The console lines ARE the gate's
 * observable: the engine's installConsole prints them as `[js] ...` to
 * stdout, so a headless-unfriendly windowed run still produces
 * machine-readable evidence.
 */
import React from 'react';
import {AppRegistry, TextInput, View} from 'react-native';

function fmt(prefix, nativeEvent) {
  const n = nativeEvent;
  return (
    `${prefix} key=${n.key} code=${n.code} ` +
    `shift=${n.shiftKey ? 1 : 0} ctrl=${n.ctrlKey ? 1 : 0} ` +
    `alt=${n.altKey ? 1 : 0} meta=${n.metaKey ? 1 : 0} ` +
    `caps=${n.capsLockKey ? 1 : 0} repeat=${n.repeat ? 1 : 0}`
  );
}

function Fixture() {
  return (
    <View
      collapsable={false}
      style={{width: 400, height: 300, backgroundColor: '#111111'}}
      onKeyDown={e => console.log(fmt('VIEW_KEYDOWN', e.nativeEvent))}
      onKeyUp={e => console.log(fmt('VIEW_KEYUP', e.nativeEvent))}>
      <TextInput
        placeholder="type"
        style={{
          width: 300,
          height: 36,
          borderWidth: 1,
          borderColor: '#888888',
          color: '#ffffff',
          marginTop: 20,
          marginLeft: 20,
        }}
        onKeyPress={e =>
          console.log(
            `TI_KEYPRESS key=${e.nativeEvent.key} eventCount=${e.nativeEvent.eventCount}`,
          )
        }
      />
    </View>
  );
}

AppRegistry.registerComponent('P0KeyEvents', () => Fixture);
