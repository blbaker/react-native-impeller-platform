/**
 * ENG-01a arm B — is the mounted "TextInput" a REAL TextInput descriptor, or
 * the Fabric interop auto-descriptor wearing plain ViewProps?
 *
 * The p9 fixture pinned height:40, so it proves layout ran but not WHOSE layout.
 * Here the TextInput has NO height. A real TextInputShadowNode measures its own
 * intrinsic content (BaseTextInputShadowNode::measureContent) and reports a
 * non-zero height for a one-line font. An interop/View descriptor has no
 * measurement of its own and reports height 0.
 *
 * Expected if REAL:    node_frame=TextInput,...,300.0,<non-zero>
 * Expected if INTEROP: node_frame=TextInput,...,300.0,0.0
 */
import React from 'react';
import {AppRegistry, Text, TextInput, View} from 'react-native';

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      <Text style={{color: '#ffffff', fontSize: 16}}>{'intrinsic'}</Text>
      <TextInput
        style={{width: 300, backgroundColor: '#ffffff', color: '#000000', fontSize: 16}}
        value="probe"
      />
    </View>
  );
}

AppRegistry.registerComponent('P9TextInput', () => Fixture);
