# Desktop notifications

The engine vends a `Notifications` native module on macOS, Linux and Windows.
Its JS half ships in the package as
`react-native-impeller-platform/src/notifications` (with TypeScript types).

```js
import Notifications from 'react-native-impeller-platform/src/notifications';

const perm = await Notifications.requestPermission();
// {status: 'granted' | 'denied' | 'unavailable' | 'error', reason?}

const shown = await Notifications.show({
  title: 'Edition ready',
  body: 'Tuesday: 3 stories',
  id: 'edition-42',          // optional; showing the same id again replaces it
  data: {edition: 42},       // optional; any JSON value, returned on press
});
// {status: 'shown' | 'denied' | 'unavailable' | 'error', id, reason?}

const sub = Notifications.onPress(({id, data, action}) => {
  // action is 'default': the user clicked the notification
});
sub.remove();
```

No call throws because a capability is missing. An engine without the module,
a platform with no backend, or a missing OS service all answer
`{status: 'unavailable', reason}`. Bad arguments (no title, `data` that
`JSON.stringify` cannot encode) reject the Promise.

## Per platform

| | Linux | macOS | Windows |
|---|---|---|---|
| API | `org.freedesktop.Notifications` on the session bus | `UNUserNotificationCenter` | WinRT toast notifications |
| `requestPermission()` | `granted` when a notification server answers; there is no prompt | the system prompt | the user's current setting; there is no prompt |
| Needs | a notification server (any desktop has one) and `libsystemd.so.0`, loaded at runtime | the engine running inside an `.app` with a `CFBundleIdentifier` | Windows 10 or later |
| Sender name | `RNI_APP_NAME`, else the executable name | the app bundle's name | `RNI_APP_NAME`, else the executable name |

Notes:

- **macOS.** A bare engine binary (for example, run straight from its npm
  package) is not in a bundle. UserNotifications raises an exception in that
  case, so the module answers `unavailable` without calling it. Ship the engine
  inside your `.app`. Notifications also show while the app is frontmost.
- **Windows.** An unpackaged app has no AppUserModelID, and Windows silently
  drops toasts for an unknown one. On first use the module registers
  `ReactNativeImpeller.<name>` under
  `HKCU\Software\Classes\AppUserModelId` with a display name. That needs no
  admin rights. When notifications are turned off (for the app, for the user,
  or by policy), `show()` answers `denied` instead of reporting a toast Windows
  would discard.
- **Linux.** The engine never links libsystemd; it loads it with `dlopen` when
  the app first calls the module. Without it, or without a session bus, the
  answer is `unavailable`. Only clicks on this process's own notifications,
  sent by the process that owns the server name, count as presses.
- **iOS and Android** engine builds answer `unavailable`.

## Limits

- A press that launches the app (the user clicks after the app quit) is not
  delivered. Presses arrive while the app is running.
- `data` round-trips through native as a JSON string. Keep it small.
- Only the default action exists. There are no buttons, images or sounds to
  configure yet.

## Tests

`tools/ci-notifications.sh` runs the Linux backend against a private
`dbus-daemon` and a fake notification server (`tools/notify_bus_mock.py`).
It checks the `Notify` call on the wire (decoded by the mock and by
`dbus-monitor`), one press with its data, a spoofed click and another app's
click being ignored, the replace on a repeated id, and `unavailable` with no
server and with no bus. `tools/mutation-verify-notifications.sh` proves each of
those checks fails when the behaviour it covers is broken.

The macOS and Windows backends have no gate yet. They were compiled on their
own hosts and driven through a small standalone program; see the commit that
added this module for what ran and what could not be observed.
