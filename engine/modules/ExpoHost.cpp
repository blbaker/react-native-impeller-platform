#include "modules/ExpoHost.h"

#include <jsi/JSIDynamic.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <random>
#include <sstream>
#include <thread>

#include "modules/ExpoHash.h"
#include "modules/NetworkingModule.h"

namespace rni {

namespace jsi = facebook::jsi;
namespace react = facebook::react;
namespace fs = std::filesystem;

namespace {

// ---------------------------------------------------------------------------
// The JS half: the four core classes and the `expo` object itself.
//
// ⛔ ES5 ON PURPOSE. This string is compiled by Hermes at runtime with no
// Babel in front of it, and it must be subclassable from app code that Babel
// DID transform (`_inherits` + `Reflect.construct`) as well as from native
// `class X extends NativeModule`. Plain constructor functions satisfy both.
//
// Semantics follow expo-modules-core's own JS reference implementation of
// the same contract (src/polyfill/CoreModule.ts): startObserving fires on the
// 0 -> 1 listener transition for an event, stopObserving on 1 -> 0, emit
// iterates a snapshot and a throwing listener does not stop the others.
// Listener tables live in a WeakMap rather than on the instance so a module's
// own keys stay exactly its functions and constants.
// ---------------------------------------------------------------------------
const char* kExpoCoreJs = R"JS(
(function (native) {
  'use strict';
  var g = globalThis;
  if (g.expo) return false;

  var tables = new WeakMap();
  function table(self) {
    var t = tables.get(self);
    if (!t) { t = new Map(); tables.set(self, t); }
    return t;
  }
  function inherit(Child, Parent) {
    Child.prototype = Object.create(Parent.prototype, {
      constructor: { value: Child, writable: true, configurable: true },
    });
    Object.setPrototypeOf(Child, Parent);
  }

  function EventEmitter() {}
  EventEmitter.prototype.addListener = function (eventName, listener) {
    var t = table(this);
    var set = t.get(eventName);
    if (!set) { set = new Set(); t.set(eventName, set); }
    var before = set.size;
    set.add(listener);
    if (before === 0 && set.size === 1) this.startObserving(eventName);
    var self = this;
    return { remove: function () { self.removeListener(eventName, listener); } };
  };
  EventEmitter.prototype.removeListener = function (eventName, listener) {
    var set = table(this).get(eventName);
    var removed = !!set && set.delete(listener);
    if (removed && set.size === 0) this.stopObserving(eventName);
  };
  EventEmitter.prototype.removeAllListeners = function (eventName) {
    var set = table(this).get(eventName);
    var had = set ? set.size : 0;
    if (set) set.clear();
    if (had > 0) this.stopObserving(eventName);
  };
  EventEmitter.prototype.emit = function (eventName) {
    var set = table(this).get(eventName);
    if (!set || set.size === 0) return;
    var args = Array.prototype.slice.call(arguments, 1);
    Array.from(set).forEach(function (listener) {
      try { listener.apply(undefined, args); } catch (e) { console.error(e); }
    });
  };
  EventEmitter.prototype.listenerCount = function (eventName) {
    var set = table(this).get(eventName);
    return set ? set.size : 0;
  };
  EventEmitter.prototype.startObserving = function (eventName) {};
  EventEmitter.prototype.stopObserving = function (eventName) {};

  function NativeModule() { EventEmitter.call(this); }
  inherit(NativeModule, EventEmitter);

  function SharedObject() { EventEmitter.call(this); }
  inherit(SharedObject, EventEmitter);
  SharedObject.prototype.release = function () {};

  function SharedRef() { SharedObject.call(this); this.nativeRefType = 'unknown'; }
  inherit(SharedRef, SharedObject);

  // Async calls: C++ settles by numeric id; no jsi value crosses a thread.
  var pending = new Map();
  var nextId = 1;
  function codedError(v) {
    var message = v && v.message != null ? String(v.message) : String(v);
    var code = v && v.code ? String(v.code) : 'ERR_UNKNOWN';
    var Coded = g.ExpoModulesCore_CodedError;
    var err;
    if (typeof Coded === 'function') {
      err = new Coded(code, message);
    } else {
      err = new Error(message);
      err.code = code;
    }
    return err;
  }
  function settle(id, ok, value) {
    var p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    if (ok) p.resolve(value); else p.reject(codedError(value));
  }
  Object.defineProperty(g, '__rniExpoSettle', { value: settle });

  function makeModule(name, def) {
    var m = new NativeModule();
    Object.defineProperty(m, '__expo_module_name__', { value: name });
    var constants = def.constants || {};
    Object.keys(constants).forEach(function (k) { m[k] = constants[k]; });
    if (typeof def.js === 'function') def.js(m, g.expo, def.host);
    (def.async || []).forEach(function (fn) {
      m[fn] = function () {
        var args = Array.prototype.slice.call(arguments);
        return new Promise(function (resolve, reject) {
          var id = nextId++;
          pending.set(id, { resolve: resolve, reject: reject });
          try {
            native.callAsync(id, name, fn, args);
          } catch (e) {
            pending.delete(id);
            reject(e);
          }
        });
      };
    });
    return m;
  }

  // One instance per module, created on first access (a module holding
  // listener state must be the same object every time, ModuleRegistry.h).
  var modules = {};
  var defs = native.defs;
  Object.keys(defs).forEach(function (name) {
    var instance = null;
    Object.defineProperty(modules, name, {
      enumerable: true,
      configurable: true,
      get: function () {
        if (instance === null) instance = makeModule(name, defs[name]);
        return instance;
      },
    });
  });

  g.expo = {
    modules: modules,
    EventEmitter: EventEmitter,
    NativeModule: NativeModule,
    SharedObject: SharedObject,
    SharedRef: SharedRef,
    uuidv4: function () { return native.uuidv4(); },
    uuidv5: function (name, namespace) {
      return native.uuidv5(String(name), String(namespace));
    },
    // No Expo native VIEWS are registered on this engine; null is the
    // contract's "not registered" answer (CoreModule.swift getViewConfig).
    getViewConfig: function (moduleName, viewName) { return null; },
    reloadAppAsync: function (reason) {
      return new Promise(function (resolve) {
        native.reload(reason == null ? '' : String(reason));
        resolve();
      });
    },
    installOnUIRuntime: function (uiRuntimeHolder) {
      throw new Error('Cannot find UI worklet runtime');
    },
    // The host is not built from expo-modules-core, so it does not claim a
    // version of it (global.ts types this `undefined | {...}`).
    expoModulesCoreVersion: undefined,
    cacheDir: native.cacheDir,
    documentsDir: native.documentsDir,
  };
  return true;
})
)JS";

std::string envOr(const char* name) {
  const char* v = std::getenv(name);
  return (v != nullptr && *v != '\0') ? std::string(v) : std::string();
}

fs::path homeDir() {
  std::string h = envOr("HOME");
#if defined(_WIN32)
  if (h.empty()) h = envOr("USERPROFILE");
#endif
  return h.empty() ? fs::path(".") : fs::path(h);
}

// file:// URL for an absolute path, percent-encoding what a URL may not
// carry raw (spaces in "Application Support", for one).
std::string fileUrl(const fs::path& p) {
  std::string s = p.lexically_normal().generic_string();
  if (s.empty() || s[0] != '/') s = "/" + s;  // C:/x -> /C:/x
  static const char* kHex = "0123456789ABCDEF";
  std::string out = "file://";
  for (unsigned char c : s) {
    const bool raw = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                     (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' ||
                     c == '~' || c == '/' || c == ':';
    if (raw) {
      out.push_back(static_cast<char>(c));
    } else {
      out.push_back('%');
      out.push_back(kHex[c >> 4]);
      out.push_back(kHex[c & 0x0f]);
    }
  }
  return out;
}

folly::dynamic codedError(const std::string& code, const std::string& message) {
  return folly::dynamic::object("code", code)("message", message);
}

bool parseUuid(const std::string& s, uint8_t out[16]) {
  if (s.size() != 36) return false;
  int n = 0;
  for (size_t i = 0; i < s.size();) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (s[i] != '-') return false;
      ++i;
      continue;
    }
    auto nib = [](char c) -> int {
      if (c >= '0' && c <= '9') return c - '0';
      if (c >= 'a' && c <= 'f') return c - 'a' + 10;
      if (c >= 'A' && c <= 'F') return c - 'A' + 10;
      return -1;
    };
    const int hi = nib(s[i]);
    const int lo = i + 1 < s.size() ? nib(s[i + 1]) : -1;
    if (hi < 0 || lo < 0) return false;
    out[n++] = static_cast<uint8_t>(hi * 16 + lo);
    i += 2;
  }
  return n == 16;
}

std::string formatUuid(const uint8_t b[16]) {
  std::string hex = expohash::toHex(b, 16);
  return hex.substr(0, 8) + "-" + hex.substr(8, 4) + "-" + hex.substr(12, 4) + "-" +
         hex.substr(16, 4) + "-" + hex.substr(20, 12);
}

std::string uuidv4() {
  static thread_local std::mt19937_64 rng{std::random_device{}()};
  uint8_t b[16];
  for (int i = 0; i < 16; i += 8) {
    const uint64_t r = rng();
    for (int j = 0; j < 8; ++j) b[i + j] = static_cast<uint8_t>(r >> (8 * j));
  }
  b[6] = static_cast<uint8_t>((b[6] & 0x0f) | 0x40);
  b[8] = static_cast<uint8_t>((b[8] & 0x3f) | 0x80);
  return formatUuid(b);
}

// RFC 4122 4.3: SHA-1(namespace bytes || name), version 5, RFC variant.
bool uuidv5(const std::string& name, const std::string& ns, std::string& out) {
  uint8_t nsBytes[16];
  if (!parseUuid(ns, nsBytes)) return false;
  std::string input(reinterpret_cast<const char*>(nsBytes), 16);
  input += name;
  auto digest = expohash::sha1(input);
  uint8_t b[16];
  for (int i = 0; i < 16; ++i) b[i] = digest[i];
  b[6] = static_cast<uint8_t>((b[6] & 0x0f) | 0x50);
  b[8] = static_cast<uint8_t>((b[8] & 0x3f) | 0x80);
  out = formatUuid(b);
  return true;
}

ExpoSettle makeSettle(std::shared_ptr<react::CallInvoker> invoker, double id) {
  auto once = std::make_shared<std::atomic<bool>>(false);
  return [invoker = std::move(invoker), id, once](bool ok, folly::dynamic value) {
    if (once->exchange(true)) return;
    invoker->invokeAsync([id, ok, value = std::move(value)](jsi::Runtime& rt) {
      auto f = rt.global().getProperty(rt, "__rniExpoSettle");
      if (!f.isObject()) return;
      auto obj = f.asObject(rt);
      if (!obj.isFunction(rt)) return;
      obj.asFunction(rt).call(rt, jsi::Value(id), jsi::Value(ok),
                              jsi::valueFromDynamic(rt, value));
    });
  };
}

bool safeNamePart(const std::string& s) {
  if (s.empty() || s.size() > 128) return false;
  for (unsigned char c : s) {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_';
    if (!ok) return false;
  }
  return true;
}

bool readFile(const fs::path& p, std::string& out) {
  std::ifstream in(p, std::ios::binary);
  if (!in) return false;
  std::ostringstream ss;
  ss << in.rdbuf();
  out = ss.str();
  return true;
}

// ExpoAsset.downloadAsync(url, md5Hash, type), the rules of AssetModule.swift:
//   file:// URL                 -> resolved unchanged (already local)
//   cached ExponentAsset-<id>.<type> whose content MD5 matches md5Hash (or
//   md5Hash is null)            -> resolved to the cached file
//   otherwise                   -> GET, write to the cache, resolve the file
// id = md5Hash, or MD5 of the URL string when the bundler gave no hash.
void downloadAsync(std::shared_ptr<ExpoHostConfig> config, folly::dynamic args,
                   ExpoSettle settle) {
  const char* kDownload = "ERR_UNABLE_TO_DOWNLOAD_ASSET";
  const char* kSave = "ERR_UNABLE_TO_SAVE_ASSET_TO_DIRECTORY";
  if (!args.isArray() || args.size() < 1 || !args[0].isString()) {
    settle(false, codedError(kDownload, "downloadAsync: url must be a string"));
    return;
  }
  const std::string url = args[0].asString();
  const std::string md5Hash =
      args.size() > 1 && args[1].isString() ? args[1].asString() : std::string();
  const std::string type =
      args.size() > 2 && args[2].isString() ? args[2].asString() : std::string();

  if (url.rfind("file://", 0) == 0) {
    settle(true, url);
    return;
  }

  const std::string cacheId = md5Hash.empty() ? expohash::md5Hex(url) : md5Hash;
  // The name is ONE path component built from JS-supplied parts; an allowlist
  // with no separators keeps it inside the cache directory.
  if (!safeNamePart(cacheId) || !safeNamePart(type)) {
    settle(false, codedError(kSave, "Unable to save asset to directory: invalid name for '" +
                                        url + "'"));
    return;
  }
  const fs::path local = config->cacheDir / ("ExponentAsset-" + cacheId + "." + type);

  auto network = config->network;
  if (network) network->inFlight.fetch_add(1);
  std::thread([url, md5Hash, local, network, settle = std::move(settle), kDownload,
               kSave]() {
    auto done = [&network]() {
      if (network) {
        network->completed.fetch_add(1);
        network->inFlight.fetch_sub(1);
      }
    };
    std::string existing;
    std::error_code ec;
    if (fs::exists(local, ec) && readFile(local, existing) &&
        (md5Hash.empty() || expohash::md5Hex(existing) == md5Hash)) {
      settle(true, fileUrl(local));
      done();
      return;
    }
    auto parsed = parseUrl(url);
    if (!parsed.valid) {
      settle(false, codedError(kDownload,
                               "Unable to download asset from url: '" + url + "'"));
      done();
      return;
    }
    auto res = performRequest("GET", parsed, {}, "", 60000);
    if (!res.ok || res.status < 200 || res.status >= 300) {
      settle(false, codedError(kDownload,
                               "Unable to download asset from url: '" + url + "'"));
      done();
      return;
    }
    fs::create_directories(local.parent_path(), ec);
    const fs::path tmp = local.string() + ".tmp";
    {
      std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
      out.write(res.body.data(), static_cast<std::streamsize>(res.body.size()));
      if (!out) {
        settle(false, codedError(kSave, "Unable to save asset to directory: '" +
                                            fileUrl(local) + "'"));
        done();
        return;
      }
    }
    fs::remove(local, ec);  // Windows rename refuses to overwrite
    fs::rename(tmp, local, ec);
    if (ec) {
      fs::remove(tmp, ec);
      settle(false, codedError(kSave, "Unable to save asset to directory: '" +
                                          fileUrl(local) + "'"));
    } else {
      settle(true, fileUrl(local));
    }
    done();
  }).detach();
}

}  // namespace

std::string expoUuidv4() { return uuidv4(); }

std::shared_ptr<ExpoHostConfig> makeExpoHostConfig() {
  auto c = std::make_shared<ExpoHostConfig>();
  const fs::path home = homeDir();

  // Cache: the OS cache location. Shared by every app this engine runs; asset
  // files are content-addressed (ExponentAsset-<md5>), so sharing is safe.
  if (auto v = envOr("RNI_CACHE_DIR"); !v.empty()) {
    c->cacheDir = v;
  } else {
#if defined(__APPLE__)
    c->cacheDir = home / "Library" / "Caches" / "rn-impeller";
#elif defined(_WIN32)
    auto local = envOr("LOCALAPPDATA");
    c->cacheDir = (local.empty() ? home / "AppData" / "Local" : fs::path(local)) /
                  "rn-impeller" / "cache";
#else
    auto xdg = envOr("XDG_CACHE_HOME");
    c->cacheDir = (xdg.empty() ? home / ".cache" : fs::path(xdg)) / "rn-impeller";
#endif
  }

  // Documents: next to the AppStorage container (ReactHost.cpp), same base.
  if (auto v = envOr("RNI_DOCUMENTS_DIR"); !v.empty()) {
    c->documentsDir = v;
  } else {
#if defined(__APPLE__)
    c->documentsDir = home / "Library" / "Application Support" / "rn-impeller" / "documents";
#else
    c->documentsDir = home / ".local" / "share" / "rn-impeller" / "documents";
#endif
  }
  return c;
}

void registerBuiltinExpoModules(ExpoModuleRegistry& registry,
                                std::shared_ptr<ExpoHostConfig> config) {
  ExpoModuleDef asset;
  asset.asyncFunctions["downloadAsync"] = [config](folly::dynamic args,
                                                   ExpoSettle settle) {
    downloadAsync(config, std::move(args), std::move(settle));
  };
  registry.add("ExpoAsset", std::move(asset));
  registerExpoConstants(registry, config);
  registerExpoFetch(registry, config);
}

void installExpoGlobal(jsi::Runtime& rt,
                       std::shared_ptr<ExpoModuleRegistry> registry,
                       std::shared_ptr<react::CallInvoker> jsInvoker,
                       std::shared_ptr<ExpoHostConfig> config) {
  jsi::Object native(rt);

  // defs: { Name: { constants: {...}, async: ['fn', ...] } }
  jsi::Object defs(rt);
  for (const auto& [name, def] : registry->defs()) {
    jsi::Object d(rt);
    d.setProperty(rt, "constants", jsi::valueFromDynamic(rt, def.constants));
    jsi::Array fns(rt, def.asyncFunctions.size());
    size_t i = 0;
    for (const auto& [fn, _] : def.asyncFunctions) {
      fns.setValueAtIndex(rt, i++, jsi::String::createFromUtf8(rt, fn));
    }
    d.setProperty(rt, "async", std::move(fns));
    if (!def.js.empty()) {
      d.setProperty(rt, "js",
                    rt.evaluateJavaScript(std::make_shared<jsi::StringBuffer>(def.js),
                                          "rni-expo-" + name + ".js"));
    }
    jsi::Object host(rt);
    if (def.installHost) def.installHost(rt, host, jsInvoker);
    d.setProperty(rt, "host", std::move(host));
    defs.setProperty(rt, name.c_str(), std::move(d));
  }
  native.setProperty(rt, "defs", std::move(defs));

  native.setProperty(
      rt, "callAsync",
      jsi::Function::createFromHostFunction(
          rt, jsi::PropNameID::forAscii(rt, "callAsync"), 4,
          [registry, jsInvoker](jsi::Runtime& rt, const jsi::Value&,
                                const jsi::Value* args, size_t count) -> jsi::Value {
            if (count < 4 || !args[0].isNumber() || !args[1].isString() ||
                !args[2].isString()) {
              throw jsi::JSError(rt, "expo callAsync: bad arguments");
            }
            const double id = args[0].asNumber();
            const std::string module = args[1].asString(rt).utf8(rt);
            const std::string fn = args[2].asString(rt).utf8(rt);
            auto settle = makeSettle(jsInvoker, id);
            const auto& defs = registry->defs();
            auto m = defs.find(module);
            if (m == defs.end() || m->second.asyncFunctions.count(fn) == 0) {
              settle(false, codedError("ERR_METHOD_NOT_FOUND",
                                       "Method '" + fn + "' not found on '" + module + "'"));
              return jsi::Value::undefined();
            }
            folly::dynamic dynArgs = jsi::dynamicFromValue(rt, args[3]);
            try {
              m->second.asyncFunctions.at(fn)(std::move(dynArgs), settle);
            } catch (const std::exception& e) {
              settle(false, codedError("ERR_UNKNOWN", e.what()));
            }
            return jsi::Value::undefined();
          }));

  native.setProperty(
      rt, "uuidv4",
      jsi::Function::createFromHostFunction(
          rt, jsi::PropNameID::forAscii(rt, "uuidv4"), 0,
          [](jsi::Runtime& rt, const jsi::Value&, const jsi::Value*, size_t) -> jsi::Value {
            return jsi::String::createFromUtf8(rt, uuidv4());
          }));

  native.setProperty(
      rt, "uuidv5",
      jsi::Function::createFromHostFunction(
          rt, jsi::PropNameID::forAscii(rt, "uuidv5"), 2,
          [](jsi::Runtime& rt, const jsi::Value&, const jsi::Value* args,
             size_t count) -> jsi::Value {
            const std::string name = count > 0 ? args[0].toString(rt).utf8(rt) : "";
            const std::string ns = count > 1 ? args[1].toString(rt).utf8(rt) : "";
            std::string out;
            if (!uuidv5(name, ns, out)) {
              throw jsi::JSError(rt, "Invalid namespace UUID: '" + ns + "'");
            }
            return jsi::String::createFromUtf8(rt, out);
          }));

  native.setProperty(
      rt, "reload",
      jsi::Function::createFromHostFunction(
          rt, jsi::PropNameID::forAscii(rt, "reload"), 1,
          [config](jsi::Runtime& rt, const jsi::Value&, const jsi::Value* args,
                   size_t count) -> jsi::Value {
            const std::string reason = count > 0 ? args[0].toString(rt).utf8(rt) : "";
            if (config->reload && *config->reload) (*config->reload)(reason);
            return jsi::Value::undefined();
          }));

  native.setProperty(rt, "cacheDir",
                     jsi::String::createFromUtf8(rt, config->cacheDir.generic_string()));
  native.setProperty(rt, "documentsDir",
                     jsi::String::createFromUtf8(rt, config->documentsDir.generic_string()));

  auto factory = rt.evaluateJavaScript(std::make_shared<jsi::StringBuffer>(kExpoCoreJs),
                                       "rni-expo-core.js");
  factory.asObject(rt).asFunction(rt).call(rt, std::move(native));
}

}  // namespace rni
