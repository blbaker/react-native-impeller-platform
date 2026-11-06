// Gate fixture for tools/ci-webview-osk.sh: an app-drawn keyboard typing into the
// web view. The app reacts to onEditableFocus the way a touchscreen kiosk does (show
// the keyboard, type), and the driver (tools/webview_osk_drive.py) does the taps.
// --initial-url webview-osk://run?base=http://127.0.0.1:PORT
// Every JS-side line is `WVAPP ...` (the [js] console prefix).
//   stage 0 tap #t        -> sendText 'abc' + sendKey Backspace, read back 'ab';
//                            sendText 'é漢', read back 'abé漢'; sendKey 'NoSuchKey' throws
//   stage 3 tap #p        -> isPassword true; sendText 'pw1', read back
//   stage 4 tap #blank    -> focused false
//   stage 5 tap #t        -> sendKey Enter submits the form (the page sets its title),
//                            then setKeepFocus(true)
//   stage 7 tap keys      -> the app's own keys t e s t (RN views in the bar, OUTSIDE
//                            the web view): each sendText's its letter into the still
//                            focused field, read back 'abé漢test'
//   stage 8 tap Done      -> the app's Done key (RN, outside): setKeepFocus(false), which
//                            blurs the view (focused false)
//   stage 9 tap #t        -> focused true again: the keyboard reopens (setKeepFocus(true),
//                            back to stage 8). Five Done -> tap cycles; before the fifth
//                            tap a physical key, which must not reach the blurred page
//   stage 10 tap RN bar   -> focused false (flag off: an outside press blurs as before)
import React from 'react';
import {AppRegistry, DeviceEventEmitter, Linking, Pressable, Text, View} from 'react-native';
import WebView from 'react-native-webview';

const log = (s) => console.log('WVAPP ' + s);
// Reads a field into document.title now AND on every later input event. A key is
// asynchronous like a physical one: measured, an injectJavaScript sent right after
// sendKey('Backspace') read 'abc', before the page had handled the key.
const watch = (id) =>
  "(function(){var e=document.getElementById('" + id + "');" +
  "var w=function(){document.title='read:'+e.value;};" +
  'if(!e.__rniWatch){e.__rniWatch=1;e.addEventListener(\'input\',w);}w();})(); true;';

function App() {
  const ref = React.useRef(null);
  const stage = React.useRef(0);
  const cycle = React.useRef(0);
  const [source, setSource] = React.useState(null);

  React.useEffect(() => {
    // The raw event the console listens to, next to the onEditableFocus prop.
    const sub = DeviceEventEmitter.addListener('impellerWebViewEvent', (ev) => {
      if (ev.type === 'editableFocus') log('raw editableFocus ' + ev.json);
    });
    Linking.getInitialURL().then((u) => {
      const m = /[?&]base=([^&]+)/.exec(u || '');
      setSource({uri: decodeURIComponent(m ? m[1] : '') + '/osk.html'});
    });
    return () => sub.remove();
  }, []);

  const next = (n, what) => {
    stage.current = n;
    log('stage ' + what);
  };

  const onEditableFocus = ({nativeEvent: n}) => {
    log('editableFocus focused=' + n.focused + ' isPassword=' + n.isPassword + ' purpose=' + n.purpose);
    const r = ref.current;
    const s = stage.current;
    if (s === 0 && n.focused && !n.isPassword) {
      stage.current = 1;
      r.sendText('abc');
      r.sendKey('Backspace');
      r.injectJavaScript(watch('t'));
    } else if (s === 3 && n.focused && n.isPassword) {
      stage.current = 4;
      r.sendText('pw1');
      r.injectJavaScript(watch('p'));
    } else if (s === 4 && !n.focused) {
      next(5, 'tap-text');
    } else if (s === 5 && n.focused && !n.isPassword) {
      stage.current = 6;
      r.sendKey('Enter');
    } else if ((s === 7 || s === 8) && !n.focused) {
      log('blurred while keeping focus');
    } else if (s === 9 && n.focused && !n.isPassword) {
      if (cycle.current < 5) {
        r.setKeepFocus(true);
        next(8, 'tap-done');
      } else {
        next(10, 'tap-chrome');
      }
    } else if (s === 10 && !n.focused) {
      next(11, 'done');
    }
  };

  // The app's keyboard: a key is an RN view outside the web view rect.
  const onKey = (k) => {
    log('key ' + k);
    ref.current.sendText(k);
  };

  // The console's Done key: the keyboard closes and lets go of the page.
  const onDone = () => {
    log('key done');
    ref.current.setKeepFocus(false);
    if (stage.current !== 8) return;
    cycle.current += 1;
    next(9, cycle.current < 5 ? 'tap-refocus' : 'tap-physical');
  };

  const onNavigationStateChange = (n) => {
    const t = n.title || '';
    if (!t.startsWith('read:') && !t.startsWith('submitted:')) return;
    log('title ' + JSON.stringify(t));
    const s = stage.current;
    if (s === 1 && t === 'read:ab') {
      stage.current = 2;
      ref.current.sendText('\u00e9\u6f22');
    } else if (s === 2 && t === 'read:ab\u00e9\u6f22') {
      try {
        ref.current.sendKey('NoSuchKey');
        log('sendKey-unknown did not throw');
      } catch (e) {
        log('sendKey-unknown threw ' + JSON.stringify(String(e && e.message)));
      }
      next(3, 'tap-password');
    } else if (s === 4 && t === 'read:pw1') {
      log('stage tap-blank');
    } else if (s === 6 && t.startsWith('submitted:')) {
      ref.current.setKeepFocus(true);
      next(7, 'tap-keys');
    } else if (s === 7 && t === 'read:ab\u00e9\u6f22test') {
      next(8, 'tap-done');
    }
  };

  // Keys sit in the bar at x 360 (Done) / 420 / 480 / 540 (50 wide), away from the
  // bar tap at 300.
  const key = (k, left, onPress = () => onKey(k)) => (
    <Pressable
      key={k}
      onPress={onPress}
      style={{position: 'absolute', left, top: 0, width: 50, height: 40, backgroundColor: '#303030'}}>
      <Text style={{color: '#fff'}}>{k}</Text>
    </Pressable>
  );

  return (
    <View style={{flex: 1, backgroundColor: '#202020'}}>
      <View style={{height: 40, backgroundColor: '#ff0000'}}>
        <Text style={{color: '#fff'}}>RN chrome</Text>
        {key('done', 360, onDone)}
        {key('t', 420)}
        {key('e', 480)}
        {key('s', 540)}
      </View>
      {source ? (
        <WebView
          ref={ref}
          source={source}
          onLoad={() => log('stage ready')}
          onEditableFocus={onEditableFocus}
          onNavigationStateChange={onNavigationStateChange}
          style={{flex: 1}}
        />
      ) : null}
    </View>
  );
}

AppRegistry.registerComponent('WebViewOskGate', () => App);
