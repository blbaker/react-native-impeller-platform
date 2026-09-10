/**
 * ENG-01 probe fixture — does <TextInput> even MOUNT on platform impeller?
 *
 * Not a gate. This exists to answer one question before any engine code is
 * written: RN's TextInput.js selects its native component with
 *
 *     if (Platform.OS === 'android') ... else if (Platform.OS === 'ios') ...
 *
 * and this platform reports Platform.OS === 'impeller', which is neither. So
 * the question "is the TextInput descriptor registered in FabricHost" may be
 * the wrong question entirely — the JS may never reach a host component at all.
 */
import React from 'react';
import {AppRegistry, Platform, Text, TextInput, View} from 'react-native';

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      <Text style={{color: '#ffffff', fontSize: 16}}>
        {'OS=' + Platform.OS}
      </Text>
      <TextInput
        style={{
          width: 300,
          height: 40,
          backgroundColor: '#ffffff',
          color: '#000000',
        }}
        value="probe"
      />
    </View>
  );
}

AppRegistry.registerComponent('P9TextInput', () => Fixture);
