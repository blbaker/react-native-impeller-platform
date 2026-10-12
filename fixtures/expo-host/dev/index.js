// ci-expo-dev entry: the Mac's probe entry plus a boot marker, so the gate can
// tell a Fast Refresh (one boot) from a reload (two), and the SC-44 checks
// (ExponentConstants from expo start's manifest, expo/fetch against the
// gate's server, passed as --initial-url rniexpo://dev?base=http://...).
import {registerRootComponent} from 'expo';
import {Linking} from 'react-native';
import App from './App';
import {checkConstants, runFetchChecks} from './fetchChecks';
console.log('EXPO_DEV_BOOT');
let pass = 0;
let fail = 0;
function check(name, ok, detail) {
  if (ok) pass++;
  else fail++;
  console.log('EXPO_DEV_CHECK ' + name + ' ' + (ok ? 'PASS' : 'FAIL') + ' ' + (detail || ''));
}
checkConstants(check);
Linking.getInitialURL()
  .then((url) => {
    const m = /[?&]base=([^&]+)/.exec(url || '');
    if (!m) return check('initial-url', false, String(url));
    return runFetchChecks(decodeURIComponent(m[1]), check);
  })
  .catch((e) => check('fetch-checks', false, 'threw ' + (e && e.message)))
  .then(() => console.log('EXPO_DEV_CHECKS_DONE pass=' + pass + ' fail=' + fail));
registerRootComponent(App);
