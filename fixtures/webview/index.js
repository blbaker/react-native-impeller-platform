// Gate fixture for tools/ci-webview.sh: react-native-webview's <WebView>,
// imported by its PACKAGE NAME so the bundle proves the metro shim resolves it.
// --initial-url webview://run?base=http://127.0.0.1:PORT&mode=main|cookie-read|cookie-clear
// Every JS-side event prints one `WVAPP` line (the [js] console prefix).
import React from 'react';
import {AppRegistry, Linking, Text, View} from 'react-native';
import WebView, {clearWebsiteData} from 'react-native-webview';

const log = (...a) => console.log('WVAPP t=' + Date.now() + ' ' + a.join(' '));
const INJECT_END = "console.log('WVPAGE injected ' + location.pathname); true;";
const INJECT_START = 'window.__early = 1;';

function parse(url) {
  const out = {};
  const q = (url || '').split('?')[1] || '';
  for (const kv of q.split('&')) {
    const [k, v] = kv.split('=');
    if (k) out[k] = decodeURIComponent(v || '');
  }
  return out;
}

function App() {
  const ref = React.useRef(null);
  const [cfg, setCfg] = React.useState(null);
  const [source, setSource] = React.useState(null);
  const st = React.useRef({aLoads: 0, slowStarted: false, stopped: false});

  React.useEffect(() => {
    Linking.getInitialURL().then((u) => {
      const c = parse(u);
      log('config', JSON.stringify(c));
      setCfg(c);
      if (c.mode === 'cookie-clear') {
        clearWebsiteData().then(
          () => { log('cleared'); setSource({uri: c.base + '/b.html'}); },
          (e) => log('clear-failed', String(e && e.message)),
        );
      } else if (c.mode === 'cookie-read') {
        setSource({uri: c.base + '/b.html'});
      } else if (c.mode === 'eme') {
        setSource({uri: c.base + '/eme.html'});
      } else {
        setSource({uri: c.base + '/a.html', headers: {'X-Rni-Gate': 'token-123'}});
      }
    });
  }, []);

  const ev = (type) => (e) => {
    const n = (e && e.nativeEvent) || {};
    log('ev=' + type, 'url=' + n.url, 'loading=' + n.loading, 'back=' + n.canGoBack,
        'fwd=' + n.canGoForward, 'title=' + JSON.stringify(n.title || ''),
        n.code !== undefined ? 'code=' + n.code : '', n.description ? 'desc=' + JSON.stringify(n.description) : '');
  };

  const onLoad = (e) => {
    ev('load')(e);
    const url = e.nativeEvent.url || '';
    if (!cfg || cfg.mode !== 'main') { log('done'); return; }
    const s = st.current;
    if (url.endsWith('/a.html')) {
      s.aLoads += 1;
      if (s.aLoads === 1) log('stage input-ready');
      else if (s.aLoads === 2) setTimeout(() => { log('call reload'); ref.current.reload(); }, 400);
      else if (s.aLoads === 3) { log('stage slow'); setSource({uri: cfg.base + '/slow'}); }
    } else if (url.endsWith('/b.html')) {
      setTimeout(() => { log('call goBack'); ref.current.goBack(); }, 400);
    }
  };

  const onLoadStart = (e) => {
    ev('loadStart')(e);
    const s = st.current;
    if ((e.nativeEvent.url || '').endsWith('/slow') && !s.slowStarted) {
      s.slowStarted = true;
      setTimeout(() => { log('call stopLoading'); s.stopCalled = true; ref.current.stopLoading(); }, 600);
    }
  };

  const onLoadEnd = (e) => {
    ev('loadEnd')(e);
    const s = st.current;
    // After a stop, loadEnd carries the COMMITTED url (a.html), not /slow.
    if (s.stopCalled && !s.stopped) {
      s.stopped = true;
      log('stage error');
      setSource({uri: cfg.base.replace(/:\d+$/, ':' + cfg.closed) + '/unreachable'});
    }
  };

  const onError = (e) => {
    ev('error')(e);
    if (cfg && cfg.mode === 'main' && (e.nativeEvent.url || '').endsWith('/unreachable')) log('done');
  };

  return (
    <View style={{flex: 1, backgroundColor: '#202020'}}>
      <View style={{height: 40, backgroundColor: '#ff0000'}}>
        <Text style={{color: '#fff'}}>RN chrome</Text>
      </View>
      {source ? (
        <WebView
          ref={ref}
          source={source}
          injectedJavaScript={INJECT_END}
          injectedJavaScriptBeforeContentLoaded={INJECT_START}
          onLoadStart={onLoadStart}
          onLoad={onLoad}
          onLoadEnd={onLoadEnd}
          onError={onError}
          onNavigationStateChange={(n) => ev('nav')({nativeEvent: n})}
          style={{flex: 1}}
        />
      ) : null}
    </View>
  );
}

AppRegistry.registerComponent('WebViewGate', () => App);
