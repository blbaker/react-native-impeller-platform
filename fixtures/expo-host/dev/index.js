// ci-expo-dev entry: the Mac's probe entry plus a boot marker, so the gate can
// tell a Fast Refresh (one boot) from a reload (two).
import {registerRootComponent} from 'expo';
import App from './App';
console.log('EXPO_DEV_BOOT');
registerRootComponent(App);
