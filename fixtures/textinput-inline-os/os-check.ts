// Acceptance 5: Platform.OS must stay 'impeller' outside the TextInput folder.
// `runtime` uses a computed key, which no build-time inliner can rewrite, so it
// is the value the Platform module really hands app code. `inlined` is the
// plain read: in a production Expo bundle it is replaced at build time, which
// shows the inliner still runs for every file outside ENG-01d's scope.
import { Platform } from 'react-native';

const key = 'OS';
const runtime = (Platform as unknown as Record<string, string>)[key];
const select = Platform.select({ impeller: 'impeller', ios: 'ios', default: 'default' });
console.log(`PROBE_PLATFORM_OS runtime=${runtime} inlined=${Platform.OS} select=${select}`);
