/**
 * ENG-16 fixture: <TextInput> vertical placement (multiline + textAlignVertical).
 *
 * Five fields, each 300 pt wide, padding 12, fontSize 16, black on white, no
 * border. Absolute positions so the gate knows each box exactly:
 *   y  10 h 100  multiline, no textAlignVertical   -> TOP (Gluestack Textarea)
 *   y 120 h 100  multiline, textAlignVertical center
 *   y 230 h 100  multiline, textAlignVertical bottom, TWO-line value
 *   y 340 h  60  single-line, no prop (control)     -> centred, unchanged
 *   y 410 h  60  single-line, textAlignVertical top
 * The gate (tools/ci-textinput-valign.sh) reads each field's ink band.
 */
import React from 'react';
import {AppRegistry, TextInput, View} from 'react-native';

function field(top, height, value, extra) {
  return (
    <TextInput
      defaultValue={value}
      style={{
        position: 'absolute',
        left: 20,
        top,
        width: 300,
        height,
        padding: 12,
        fontSize: 16,
        color: '#000000',
        ...extra.style,
      }}
      multiline={extra.multiline}
    />
  );
}

function Fixture() {
  return (
    <View style={{width: 400, height: 480, backgroundColor: '#ffffff'}}>
      {field(10, 100, 'Top line', {multiline: true, style: {}})}
      {field(120, 100, 'Centre line', {multiline: true, style: {textAlignVertical: 'center'}})}
      {field(230, 100, 'Bottom one\nBottom two', {multiline: true, style: {textAlignVertical: 'bottom'}})}
      {field(340, 60, 'Single auto', {multiline: false, style: {}})}
      {field(410, 60, 'Single top', {multiline: false, style: {textAlignVertical: 'top'}})}
    </View>
  );
}

AppRegistry.registerComponent('Eng16TextAlignVertical', () => Fixture);
