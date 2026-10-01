/**
 * parity item 13 fixture: the bundle is loaded from a Metro dev server.
 *
 * Logs what getDevServer() reports (bundleLoadedFromServer + url) and the
 * SourceCode scriptURL, plus a marker the gate rewrites in the SOURCE file to
 * prove the bundle came from Metro's live view of the source tree.
 */
import React from 'react';
import {AppRegistry, NativeModules, View} from 'react-native';
import getDevServer from 'react-native/Libraries/Core/Devtools/getDevServer';

const MARK = 'METRO_MARK_ORIGINAL';
const ds = getDevServer();
console.log('METRO_FROM_SERVER ' + String(ds.bundleLoadedFromServer));
console.log('METRO_URL ' + ds.url);
console.log('METRO_MARK ' + MARK);
const sc = NativeModules.SourceCode || null;
console.log(
  'METRO_SCRIPT_URL ' +
    String(sc && sc.getConstants ? sc.getConstants().scriptURL : 'n/a'),
);

function Fixture() {
  return <View style={{width: 400, height: 300, backgroundColor: '#224466'}} />;
}

AppRegistry.registerComponent('Item13Metro', () => Fixture);
