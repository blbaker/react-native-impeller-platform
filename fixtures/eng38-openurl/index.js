/**
 * ENG-38 fixture (tools/ci-openurl-window.sh): Linking.openURL from JS.
 *
 * Opens 'https://example.com/?a=1&b=2' (the literal, with & ), unless the
 * engine was launched with --initial-url, in which case it opens THAT string.
 * The gate uses the override for its hostile control arm, so one bundle
 * covers both directions.
 *
 * Logs (stdout, via [js]):
 *   ENG38 target=<url>
 *   ENG38 resolved=<true|false|threw:...>
 *   ENG38 DONE
 * The engine itself prints `rn-impeller: openURL=<url>` (stdout) when it
 * launches, or `rn-impeller: openURL REFUSED ...` (stderr) when it refuses.
 */
const React = require('react');
const { AppRegistry, Linking, View } = require('react-native');
const h = React.createElement;

const DEFAULT_URL = 'https://example.com/?a=1&b=2';

function App() {
  React.useEffect(() => {
    (async () => {
      const initial = await Linking.getInitialURL();
      const target = initial || DEFAULT_URL;
      console.log('ENG38 target=' + target);
      let r;
      try {
        r = await Linking.openURL(target);
      } catch (e) {
        r = 'threw:' + (e && e.message);
      }
      console.log('ENG38 resolved=' + r);
      console.log('ENG38 DONE');
    })();
  }, []);
  return h(View, { style: { flex: 1, backgroundColor: 'rgb(18,52,86)' } });
}

AppRegistry.registerComponent('Eng38OpenUrl', () => App);
