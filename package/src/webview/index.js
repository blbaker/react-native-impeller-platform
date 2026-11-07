'use strict';
// react-native-webview's <WebView> on rn-impeller.
//
//   import WebView from 'react-native-webview';   // the metro shim resolves it here
//   <WebView source={{uri: 'https://example.com', headers: {Authorization: '...'}}}
//            injectedJavaScript="..." onLoadStart onLoad onLoadEnd onError
//            onNavigationStateChange ref={r} />
//   r.goBack() r.goForward() r.reload() r.stopLoading() r.injectJavaScript(js)
//
// App-drawn keyboard (the target device has no OS input method):
//   <WebView onEditableFocus={({nativeEvent: {focused, isPassword, purpose}}) => ...} />
//     fires when a page editable gains (focused true) or loses input focus; purpose is
//     free-form | digits | number | phone | url | email | password | search (null when
//     not focused). The raw DeviceEventEmitter 'impellerWebViewEvent' carries the same
//     event as type 'editableFocus' (json = that object as a string).
//   r.sendText(text)   commits text into the focused editable as an input method does
//                      (beforeinput/input fire; any Unicode)
//   r.sendKey(name)    presses + releases a named key, as a physical keyboard does:
//                      Backspace Enter Tab Escape Delete Home End ArrowLeft ArrowRight
//                      ArrowUp ArrowDown (also Insert PageUp PageDown F1..F24); an
//                      unknown name throws
//   r.setKeepFocus(keep) while true, a press OUTSIDE the web view (your keyboard's
//                      keys) does not blur the page, so its focused editable keeps
//                      taking sendText/sendKey. Set it when you open your keyboard,
//                      clear it when you close it. Clearing blurs the page
//                      (onEditableFocus focused:false), so the next tap on the same
//                      field fires focused:true again and you can reopen. Presses
//                      inside the page are unchanged: tapping the page outside a
//                      field still blurs it.
// All three throw when the engine predates them.
//
// The page is rendered by WPE WebKit in the engine's rni-webhelper process and
// painted through <ImpellerTextureView textureId> (FP-42), so it clips,
// transforms and fades like any view. Mouse, wheel and keys reach the page
// natively (engine/webview/WebViewInput.cpp), with no JS round trip.
// rn-impeller-webview-shim (marker the gate greps for in a bundle)
const React = require('react');
const {TurboModuleRegistry, View, DeviceEventEmitter, PixelRatio} = require('react-native');
const {ImpellerTextureView} = require('../externaltexture');

const Native = TurboModuleRegistry.get('ImpellerWebView');

function isSupported() {
  return Native != null && Native.isSupported();
}

// The helper's report once it connected: {protocol, webkit, eme, cdm}; {} before.
function status() {
  return Native == null ? {} : JSON.parse(Native.status());
}

// Host-wide: cookies, local storage, cache (member sign-out). Resolves when done.
function clearWebsiteData() {
  if (Native == null) return Promise.reject(new Error('ImpellerWebView is unavailable'));
  return new Promise((resolve, reject) => {
    const sub = DeviceEventEmitter.addListener('impellerWebViewEvent', (ev) => {
      if (ev.type !== 'dataCleared') return;
      sub.remove();
      const r = JSON.parse(ev.json);
      if (r.ok) resolve();
      else reject(new Error(r.error || 'clearWebsiteData failed'));
    });
    Native.clearWebsiteData();
  });
}

const handlers = new Map();  // view id -> event handler
let subscription = null;
function listen(id, fn) {
  handlers.set(id, fn);
  if (subscription == null) {
    subscription = DeviceEventEmitter.addListener('impellerWebViewEvent', (ev) => {
      const h = handlers.get(ev.id);
      if (h) h(ev);
    });
  }
}
function unlisten(id) {
  handlers.delete(id);
  if (handlers.size === 0 && subscription) {
    subscription.remove();
    subscription = null;
  }
}

function headersOf(source) {
  const out = {};
  const h = source && source.headers;
  if (h && typeof h === 'object') {
    for (const k of Object.keys(h)) {
      if (h[k] != null) out[k] = String(h[k]);
    }
  }
  return out;
}

const WebView = React.forwardRef(function WebView(props, ref) {
  const {source, style, containerStyle, onLayout} = props;
  const propsRef = React.useRef(props);
  propsRef.current = props;
  const idRef = React.useRef(0);
  const [id, setId] = React.useState(0);
  const uri = source && typeof source.uri === 'string' ? source.uri : '';
  const headers = headersOf(source);
  const sourceKey = JSON.stringify([uri, headers]);

  const fail = React.useCallback((description) => {
    const p = propsRef.current;
    const nativeEvent = {url: uri, code: -1, domain: 'rn-impeller', description};
    if (p.onError) p.onError({nativeEvent});
    if (p.onLoadEnd) p.onLoadEnd({nativeEvent});
  }, [uri]);

  const onEvent = React.useCallback((ev) => {
    const p = propsRef.current;
    let nativeEvent;
    try {
      nativeEvent = JSON.parse(ev.json);
    } catch (e) {
      nativeEvent = {};
    }
    switch (ev.type) {
      case 'loadStart': if (p.onLoadStart) p.onLoadStart({nativeEvent}); break;
      case 'load': if (p.onLoad) p.onLoad({nativeEvent}); break;
      case 'loadEnd': if (p.onLoadEnd) p.onLoadEnd({nativeEvent}); break;
      case 'error': if (p.onError) p.onError({nativeEvent}); break;
      case 'navState': if (p.onNavigationStateChange) p.onNavigationStateChange(nativeEvent); break;
      case 'editableFocus': if (p.onEditableFocus) p.onEditableFocus({nativeEvent}); break;
      default: break;
    }
  }, []);

  // An engine older than the app keyboard API has no such method: say so, not "undefined".
  const needs = (fn) => {
    if (typeof Native[fn] !== 'function') {
      throw new Error('ImpellerWebView.' + fn + ' is unavailable: the engine predates the app keyboard API');
    }
  };

  React.useImperativeHandle(ref, () => ({
    goBack: () => idRef.current && Native.goBack(idRef.current),
    goForward: () => idRef.current && Native.goForward(idRef.current),
    reload: () => idRef.current && Native.reload(idRef.current),
    stopLoading: () => idRef.current && Native.stopLoading(idRef.current),
    injectJavaScript: (js) => idRef.current && Native.injectJavaScript(idRef.current, String(js)),
    sendText: (text) => { needs('sendText'); return idRef.current && Native.sendText(idRef.current, String(text)); },
    sendKey: (name) => { needs('sendKey'); return idRef.current && Native.sendKey(idRef.current, String(name)); },
    setKeepFocus: (keep) => { needs('setKeepFocus'); return idRef.current && Native.setKeepFocus(idRef.current, !!keep); },
    clearCache: () => clearWebsiteData(),
    requestFocus: () => {},
  }), []);

  // Scripts first: the effect order makes them part of the FIRST page too.
  React.useEffect(() => {
    if (!id) return;
    Native.setInjectedJavaScript(id, props.injectedJavaScript || '', false);
    Native.setInjectedJavaScript(id, props.injectedJavaScriptBeforeContentLoaded || '', true);
  }, [id, props.injectedJavaScript, props.injectedJavaScriptBeforeContentLoaded]);

  React.useEffect(() => {
    if (id && uri) Native.load(id, uri, headers);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, sourceKey]);

  React.useEffect(() => () => {
    if (idRef.current) {
      unlisten(idRef.current);
      Native.release(idRef.current);
      idRef.current = 0;
    }
  }, []);

  const layout = (e) => {
    const {width, height} = e.nativeEvent.layout;
    const w = Math.max(1, Math.round(width)), h = Math.max(1, Math.round(height));
    const scale = PixelRatio.get();
    if (!idRef.current) {
      if (Native == null) {
        fail('ImpellerWebView native module is unavailable: the engine predates the web view.');
      } else {
        try {
          const v = Native.create(w, h, scale, propsRef.current.userAgent || '');
          idRef.current = v;
          listen(v, onEvent);
          setId(v);
        } catch (err) {
          fail(String((err && err.message) || err));
        }
      }
    } else {
      Native.resize(idRef.current, w, h, scale);
    }
    if (onLayout) onLayout(e);
  };

  return React.createElement(
    View,
    {style: [{flex: 1, overflow: 'hidden'}, containerStyle, style], onLayout: layout, testID: props.testID},
    id
      ? React.createElement(ImpellerTextureView, {
          textureId: id,
          style: {position: 'absolute', left: 0, top: 0, right: 0, bottom: 0},
        })
      : null,
  );
});

module.exports = {
  __esModule: true,
  default: WebView,
  WebView,
  isSupported,
  status,
  clearWebsiteData,
  implementation: 'rn-impeller-webview-shim',  // the gate greps a bundle for this
};
