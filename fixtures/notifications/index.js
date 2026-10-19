/**
 * Notifications gate fixture (tools/ci-notifications.sh).
 *
 * The mode arrives by --initial-url, because Hermes has no process.env:
 *   rninotify://press   a notification server is on the bus and will click
 *                       the notification; wait for the press, then show the
 *                       same id again (a replace)
 *   rninotify://absent  no server, or no bus at all; every answer must be
 *                       "unavailable" and nothing may crash
 *
 * Every result leaves the process as an Alert title, so the gate asserts on
 * values JS actually received, not on native counters.
 */
import React from 'react';
import {Alert, AppRegistry, Linking, Text, View} from 'react-native';
import Notifications from 'react-native-impeller-platform/src/notifications';

const report = message => Alert.alert('notif ' + message);
const withReason = r => (r.reason ? ' reason=' + r.reason : '');

// The press sequence the gate's bus mock sends: a spoofed click from a client
// that does not own the server name, a click on another app's notification,
// then the real click. Only the last may arrive here. Presses are collected
// for a short settle after the first one so an extra press is counted.
const SETTLE_MS = 500;

function waitForPresses() {
  return new Promise(resolve => {
    const presses = [];
    const sub = Notifications.onPress(event => {
      presses.push(event);
      if (presses.length === 1) {
        setTimeout(() => {
          sub.remove();
          resolve(presses);
        }, SETTLE_MS);
      }
    });
  });
}

async function run() {
  // Holds the headless run open while native work is in flight (an idle JS
  // thread would end it), and reports a hang instead of exiting quietly.
  const keepalive = setTimeout(() => report('timeout'), 8000);
  const url = (await Linking.getInitialURL()) || '';
  const mode = url.replace('rninotify://', '');

  const bad = await Notifications.show({}).then(
    () => 'resolved',
    () => 'rejected',
  );
  const perm = await Notifications.requestPermission();
  report(`perm=${perm.status} bad=${bad}${withReason(perm)}`);

  const pressed = mode === 'press' ? waitForPresses() : null;
  const shown = await Notifications.show({
    title: 'Edition ready',
    body: 'Tuesday: 3 stories',
    id: 'edition-42',
    data: {edition: 42, kind: 'edition'},
  });
  report(`show=${shown.status} id=${shown.id}${withReason(shown)}`);

  if (pressed) {
    const presses = await pressed;
    const first = presses[0];
    report(
      `press n=${presses.length} id=${first.id} action=${first.action} ` +
        `data=${JSON.stringify(first.data)}`,
    );
    const again = await Notifications.show({
      title: 'Edition ready (updated)',
      body: 'Tuesday: 4 stories',
      id: 'edition-42',
      data: {edition: 42, kind: 'edition', rev: 2},
    });
    report(`replace=${again.status} id=${again.id}${withReason(again)}`);
  }
  clearTimeout(keepalive);
  report('done');
}

function App() {
  React.useEffect(() => {
    run().catch(error => report('error ' + String(error && error.message)));
  }, []);
  return (
    <View style={{width: 400, height: 300}}>
      <Text>notifications</Text>
    </View>
  );
}

AppRegistry.registerComponent('NotifyFixture', () => App);
