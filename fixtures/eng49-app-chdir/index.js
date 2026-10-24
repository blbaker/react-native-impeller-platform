/**
 * ENG-49 fixture for tools/ci-app-chdir.sh (from the Mac's ENG-49-ASK-1
 * probe). One filled View, so a capture has something to write. The gate
 * grades WHERE the frame lands, not what it shows.
 */
const React = require('react');
const { AppRegistry, View } = require('react-native');

function Fixture() {
  return React.createElement(View, {
    style: { width: 200, height: 120, backgroundColor: '#22aa66' },
  });
}

AppRegistry.registerComponent('AppChdirProbe', () => Fixture);
