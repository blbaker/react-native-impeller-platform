/**
 * ENG-01b edit probe — the peer's acceptance probe, verbatim in intent.
 *
 * A controlled <TextInput>: value is React state, onChangeText writes it back,
 * and a <Text> below renders `len=${v.length} v=${v}` so the JS-side truth is
 * on screen and in the node dump. The engine's --type harness focuses the
 * field, types, backspaces and submits; a gate asserts BOTH the engine buffer
 * (rn-impeller: textinput_value ...) AND this label agree.
 */
import React from 'react';
import {AppRegistry, Text, TextInput, View} from 'react-native';

function Fixture() {
  const [v, setV] = React.useState('');
  const [submitted, setSubmitted] = React.useState(false);
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      <TextInput
        value={v}
        onChangeText={setV}
        onSubmitEditing={() => setSubmitted(true)}
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
      />
      <Text style={{color: '#ffffff', fontSize: 16, marginLeft: 20}}>
        {`len=${v.length} v=${v}`}
      </Text>
      <Text style={{color: '#00ff88', fontSize: 16, marginLeft: 20}}>
        {`submitted=${submitted ? 'yes' : 'no'}`}
      </Text>
    </View>
  );
}

AppRegistry.registerComponent('P9TextInput', () => Fixture);
