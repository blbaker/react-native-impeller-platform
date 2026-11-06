// "ImpellerWebView" TurboModule: the JS face of WebViewHost. package/src/webview
// wraps it as react-native-webview's <WebView> (the metro shim resolves
// `react-native-webview` there), painting through <ImpellerTextureView>.
//   isSupported() -> bool        status() -> json string (helper version, eme, cdm)
//   create(width, height, scale, userAgent) -> id   (throws with the reason)
//   load(id, url, headers{})     resize(id, w, h, scale)
//   goBack/goForward/reload/stopLoading(id)
//   injectJavaScript(id, js)     setInjectedJavaScript(id, js, beforeContentLoaded)
//   release(id) -> bool          clearWebsiteData()   (cookies, storage, cache)
//   sendText(id, text)           app-drawn keyboard: commit text into the focused editable
//   sendKey(id, name)            press + release a named key (WebViewInput::KeysymForKey:
//                                Backspace Enter Tab Escape Delete Insert Home End PageUp
//                                PageDown ArrowLeft/Up/Right/Down F1..F24 ...); an unknown
//                                name throws
//   setKeepFocus(id, keep)       while true, a press outside every web view (the app's
//                                keyboard keys) keeps this view and its focused editable
//                                focused; false blurs the view if it is focused, so the
//                                next tap on the field reports editableFocus again
// Events: DeviceEventEmitter "impellerWebViewEvent" {id, type, json}; type is
// loadStart | load | loadEnd | error | navState | dataCleared | editableFocus
// ({focused, isPassword, purpose}: a page editable gained or lost input focus).
#pragma once

#include <ReactCommon/TurboModule.h>

#include <cmath>
#include <memory>
#include <mutex>
#include <set>
#include <string>

#include "scenegraph/TextureRegistry.h"
#include "webview/WebViewHost.h"
#include "webview/WebViewInput.h"

namespace rni {

class WebViewModule : public facebook::react::TurboModule {
 public:
  WebViewModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                std::shared_ptr<TextureRegistry> registry)
      : facebook::react::TurboModule("ImpellerWebView", std::move(jsInvoker)),
        registry_(std::move(registry)) {
    methodMap_["isSupported"] = MethodMetadata{0, isSupportedHost};
    methodMap_["status"] = MethodMetadata{0, statusHost};
    methodMap_["create"] = MethodMetadata{4, createHost};
    methodMap_["load"] = MethodMetadata{3, loadHost};
    methodMap_["resize"] = MethodMetadata{4, resizeHost};
    methodMap_["goBack"] = MethodMetadata{1, navHost<0>};
    methodMap_["goForward"] = MethodMetadata{1, navHost<1>};
    methodMap_["reload"] = MethodMetadata{1, navHost<2>};
    methodMap_["stopLoading"] = MethodMetadata{1, navHost<3>};
    methodMap_["injectJavaScript"] = MethodMetadata{2, injectHost};
    methodMap_["setInjectedJavaScript"] = MethodMetadata{3, userScriptHost};
    methodMap_["release"] = MethodMetadata{1, releaseHost};
    methodMap_["clearWebsiteData"] = MethodMetadata{0, clearHost};
    methodMap_["sendText"] = MethodMetadata{2, sendTextHost};
    methodMap_["sendKey"] = MethodMetadata{2, sendKeyHost};
    methodMap_["setKeepFocus"] = MethodMetadata{2, keepFocusHost};
    methodMap_["addListener"] = MethodMetadata{1, noopHost};
    methodMap_["removeListeners"] = MethodMetadata{1, noopHost};
    WebViewHost::Instance().SetEventListener(
        [this](int64_t id, const std::string& type, const std::string& json) {
          emitDeviceEvent("impellerWebViewEvent",
                          [id, type, json](facebook::jsi::Runtime& rt, std::vector<facebook::jsi::Value>& args) {
                            facebook::jsi::Object o(rt);
                            o.setProperty(rt, "id", (double)id);
                            o.setProperty(rt, "type", facebook::jsi::String::createFromUtf8(rt, type));
                            o.setProperty(rt, "json", facebook::jsi::String::createFromUtf8(rt, json));
                            args.emplace_back(std::move(o));
                          });
        });
  }

  ~WebViewModule() override {
    WebViewHost::Instance().SetEventListener(nullptr);  // returns once no emit is running
    std::set<int64_t> ids;
    {
      std::lock_guard<std::mutex> lock(mu_);
      ids.swap(ids_);
    }
    for (int64_t id : ids) WebViewHost::Instance().Destroy(id);
  }

 private:
  using Runtime = facebook::jsi::Runtime;
  using Value = facebook::jsi::Value;
  using TM = facebook::react::TurboModule;
  static WebViewModule& self(TM& tm) { return static_cast<WebViewModule&>(tm); }
  static WebViewHost& host() { return WebViewHost::Instance(); }

  [[noreturn]] static void bad(Runtime& rt, const std::string& fn, const char* want) {
    throw facebook::jsi::JSError(rt, "ImpellerWebView." + fn + ": expected " + want);
  }
  static int64_t id(Runtime& rt, const Value* a, size_t n, const char* fn) {
    if (n < 1 || !a[0].isNumber() || a[0].asNumber() < 1 || std::floor(a[0].asNumber()) != a[0].asNumber())
      bad(rt, fn, "a web view id (positive integer)");
    return (int64_t)a[0].asNumber();
  }
  static std::string str(Runtime& rt, const Value* a, size_t n, size_t i, const char* fn) {
    if (n <= i || !a[i].isString()) bad(rt, fn, "a string argument");
    return a[i].asString(rt).utf8(rt);
  }
  static double num(Runtime& rt, const Value* a, size_t n, size_t i, const char* fn) {
    if (n <= i || !a[i].isNumber() || !std::isfinite(a[i].asNumber())) bad(rt, fn, "a finite number");
    return a[i].asNumber();
  }

  static Value noopHost(Runtime&, TM&, const Value*, size_t) { return Value::undefined(); }
  static Value isSupportedHost(Runtime&, TM&, const Value*, size_t) {
    return Value(host().Supported(nullptr));
  }
  static Value statusHost(Runtime& rt, TM&, const Value*, size_t) {
    return facebook::jsi::String::createFromUtf8(rt, host().StatusJson());
  }
  static Value createHost(Runtime& rt, TM& tm, const Value* a, size_t n) {
    const int w = (int)num(rt, a, n, 0, "create"), h = (int)num(rt, a, n, 1, "create");
    const double scale = num(rt, a, n, 2, "create");
    const std::string ua = n > 3 && a[3].isString() ? a[3].asString(rt).utf8(rt) : "";
    std::string error;
    const int64_t v = host().Create(self(tm).registry_, w, h, scale, ua, &error);
    if (!v) throw facebook::jsi::JSError(rt, "ImpellerWebView.create: " + error);
    std::lock_guard<std::mutex> lock(self(tm).mu_);
    self(tm).ids_.insert(v);
    return Value((double)v);
  }
  static Value loadHost(Runtime& rt, TM&, const Value* a, size_t n) {
    const int64_t v = id(rt, a, n, "load");
    const std::string url = str(rt, a, n, 1, "load");
    WebViewHost::Headers headers;
    if (n > 2 && a[2].isObject()) {
      auto obj = a[2].asObject(rt);
      auto names = obj.getPropertyNames(rt);
      for (size_t i = 0; i < names.size(rt); ++i) {
        auto k = names.getValueAtIndex(rt, i).asString(rt).utf8(rt);
        auto val = obj.getProperty(rt, k.c_str());
        if (val.isString()) headers.emplace_back(k, val.asString(rt).utf8(rt));
        else if (val.isNumber()) headers.emplace_back(k, std::to_string((long long)val.asNumber()));
      }
    }
    host().Load(v, url, headers);
    return Value::undefined();
  }
  static Value resizeHost(Runtime& rt, TM&, const Value* a, size_t n) {
    host().Resize(id(rt, a, n, "resize"), (int)num(rt, a, n, 1, "resize"),
                  (int)num(rt, a, n, 2, "resize"), num(rt, a, n, 3, "resize"));
    return Value::undefined();
  }
  template <int K>
  static Value navHost(Runtime& rt, TM&, const Value* a, size_t n) {
    static const char* names[] = {"back", "forward", "reload", "stop"};
    host().Nav(id(rt, a, n, names[K]), names[K]);
    return Value::undefined();
  }
  static Value injectHost(Runtime& rt, TM&, const Value* a, size_t n) {
    host().Inject(id(rt, a, n, "injectJavaScript"), str(rt, a, n, 1, "injectJavaScript"));
    return Value::undefined();
  }
  static Value userScriptHost(Runtime& rt, TM&, const Value* a, size_t n) {
    const bool atStart = n > 2 && a[2].isBool() && a[2].getBool();
    host().UserScript(id(rt, a, n, "setInjectedJavaScript"), str(rt, a, n, 1, "setInjectedJavaScript"),
                      atStart);
    return Value::undefined();
  }
  static Value releaseHost(Runtime& rt, TM& tm, const Value* a, size_t n) {
    const int64_t v = id(rt, a, n, "release");
    {
      std::lock_guard<std::mutex> lock(self(tm).mu_);
      self(tm).ids_.erase(v);
    }
    host().SetKeepFocus(v, false);
    return Value(host().Destroy(v));
  }
  static Value clearHost(Runtime&, TM&, const Value*, size_t) {
    host().ClearData();
    return Value::undefined();
  }
  static Value sendTextHost(Runtime& rt, TM&, const Value* a, size_t n) {
    host().Text(id(rt, a, n, "sendText"), str(rt, a, n, 1, "sendText"));
    return Value::undefined();
  }
  // The same key-down + key-up the GLFW key callback sends for a focused view.
  static Value sendKeyHost(Runtime& rt, TM&, const Value* a, size_t n) {
    const int64_t v = id(rt, a, n, "sendKey");
    const std::string name = str(rt, a, n, 1, "sendKey");
    const uint32_t sym = WebViewInput::KeysymForKey(name);
    if (!sym)
      throw facebook::jsi::JSError(rt, "ImpellerWebView.sendKey: unknown key '" + name +
                                           "' (named keys only; send characters with sendText)");
    host().Key(v, true, sym, 0, 0);
    host().Key(v, false, sym, 0, 0);
    return Value::undefined();
  }
  static Value keepFocusHost(Runtime& rt, TM&, const Value* a, size_t n) {
    const int64_t v = id(rt, a, n, "setKeepFocus");
    if (n < 2 || !a[1].isBool()) bad(rt, "setKeepFocus", "a boolean");
    host().SetKeepFocus(v, a[1].getBool());
    return Value::undefined();
  }

  std::shared_ptr<TextureRegistry> registry_;
  std::mutex mu_;
  std::set<int64_t> ids_;
};

}  // namespace rni
