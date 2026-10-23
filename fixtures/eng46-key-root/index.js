// ENG-46 fixture. Two apps in one bundle (pick with --app-name).
//
// KeyRootProbe: the Mac's probe from its bug report, verbatim, plus an
// onKeyUp twin so the release path is proven as well. Nothing here is
// focusable, so a key press has no focused TextInput and no focused View.
// Before ENG-46 the engine fell back to the SURFACE ROOT (tag 1), which has no
// React instance, so this onKeyDown never fired. The fix sends the event to
// the root React component's top host view, and it bubbles up to this View
// the way a focused event does.
//
// KeyRootField: the same root handler, with a TextInput as the FIRST host
// child. Unfocused, a key must bubble to the root handler WITHOUT firing the
// field's onKeyPress (the field does not have focus). Clicked into, the
// focused-field path must be unchanged: onKeyPress fires and the key still
// bubbles to the root handler.
import React from 'react';
import {AppRegistry, View, Text, TextInput} from 'react-native';

function App() {
  return (
    <View
      style={{flex: 1}}
      onKeyDown={e =>
        console.log(
          'KEYROOT',
          e.nativeEvent.key,
          e.nativeEvent.metaKey,
          e.nativeEvent.shiftKey,
        )
      }
      onKeyUp={e =>
        console.log(
          'KEYROOT_UP',
          e.nativeEvent.key,
          e.nativeEvent.metaKey,
          e.nativeEvent.shiftKey,
        )
      }>
      <Text>key root probe</Text>
    </View>
  );
}

function FieldApp() {
  return (
    <View
      style={{flex: 1}}
      onKeyDown={e =>
        console.log(
          'FIELDROOT',
          e.nativeEvent.key,
          e.nativeEvent.metaKey,
          e.nativeEvent.shiftKey,
        )
      }>
      <TextInput
        style={{width: 360, height: 120, borderWidth: 1, fontSize: 16}}
        onKeyPress={e => console.log('TI_KEYPRESS', e.nativeEvent.key)}
      />
      <Text>field probe</Text>
    </View>
  );
}

AppRegistry.registerComponent('KeyRootProbe', () => App);
AppRegistry.registerComponent('KeyRootField', () => FieldApp);
