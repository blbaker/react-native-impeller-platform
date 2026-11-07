// the board acceptance fixture: the exact <WebView> the
// app lane uses, pointed at https://example.com. One WVAPP line per load event so
// a run can wait for the load before it takes --screenshot.
import React from 'react';
import {AppRegistry, View} from 'react-native';
import WebView from 'react-native-webview';

const log = (...a) => console.log('WVAPP t=' + Date.now() + ' ' + a.join(' '));

function App() {
  return (
    <View style={{flex: 1, backgroundColor: '#202020'}}>
      <WebView
        source={{uri: 'https://example.com'}}
        onLoadStart={(e) => log('ev=loadStart url=' + e.nativeEvent.url)}
        onLoad={(e) => log('ev=load url=' + e.nativeEvent.url + ' title=' + e.nativeEvent.title)}
        onError={(e) => log('ev=error ' + JSON.stringify(e.nativeEvent))}
        style={{flex: 1}}
      />
    </View>
  );
}

AppRegistry.registerComponent('WebViewExample', () => App);
