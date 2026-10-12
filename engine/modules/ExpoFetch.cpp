// ExpoFetchModule: the native half of expo/fetch (SC-44).
//
// expo's winter runtime REPLACES globalThis.fetch with expo/fetch, which does
// requireNativeModule('ExpoFetchModule') on first use. Without this module
// every fetch() in an Expo app threw "Cannot find native module
// 'ExpoFetchModule'" (expo start dev boot logs it on the Mac and here).
//
// The JS half (ExpoFetchJs.h) defines NativeRequest / NativeResponse as
// SharedObjects; this file is the transport: one detached worker per request
// over performRequest (NetworkingModule's asio client, the same one RN's
// fetch/XHR use), plus the redirect modes performRequest does not do.
//
// LIMITS, said out loud:
//   - The body is read whole, then handed to JS; NativeResponse streams it
//     to the ReadableStream in 64 KB chunks after that. No progressive
//     download.
//   - https works where NetworkingModule has TLS (RNI_WITH_TLS). win32 has no
//     TLS: the request fails with the transport's "https is not supported"
//     message, as RN fetch does there.
//   - No cookie jar (credentials is accepted and ignored).
//   - unstable_createBlobData keeps the bytes under a uuid, but this engine
//     vends no BlobModule, so nothing reads a Blob's bytes back yet.
//
// No jsi value crosses a thread: the worker posts plain C++ data through the
// CallInvoker and builds the JS values on the JS thread.
#include "modules/ExpoHost.h"

#include <cctype>
#include <cstring>
#include <mutex>
#include <set>
#include <thread>

#include "modules/ExpoFetchJs.h"
#include "modules/NetworkingModule.h"

namespace rni {

namespace jsi = facebook::jsi;
namespace react = facebook::react;

namespace {

struct FetchResult {
  bool ok{false};
  std::string error;
  int status{0};
  std::string statusText;
  std::string url;
  bool redirected{false};
  std::map<std::string, std::string> headers;
  std::string body;
};

struct FetchState {
  std::mutex mutex;
  std::set<double> cancelled;
  std::map<std::string, std::string> blobs;
};

std::string lower(std::string s) {
  for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return s;
}

// Location may be absolute, scheme-relative, origin-relative or path-relative.
std::string resolveLocation(const std::string& base, const std::string& loc) {
  if (loc.find("://") != std::string::npos) return loc;
  const size_t se = base.find("://");
  const std::string scheme = base.substr(0, se);
  if (loc.rfind("//", 0) == 0) return scheme + ":" + loc;
  const size_t pathStart = base.find('/', se + 3);
  const std::string origin = pathStart == std::string::npos ? base : base.substr(0, pathStart);
  if (!loc.empty() && loc[0] == '/') return origin + loc;
  std::string path = pathStart == std::string::npos ? "/" : base.substr(pathStart);
  path = path.substr(0, path.find('?'));
  return origin + path.substr(0, path.rfind('/') + 1) + loc;
}

FetchResult runFetch(std::string url, std::string method,
                     std::map<std::string, std::string> headers, std::string body,
                     const std::string& redirect) {
  FetchResult r;
  for (int hop = 0;; ++hop) {
    auto parsed = parseUrl(url);
    if (!parsed.valid) {
      r.error = parsed.error;
      return r;
    }
    auto res = performRequest(method, parsed, headers, body, 0);
    if (!res.ok) {
      r.error = res.error;
      return r;
    }
    std::string location;
    for (const auto& [k, v] : res.headers) {
      if (lower(k) == "location") location = v;
    }
    const int s = res.status;
    const bool isRedirect = (s == 301 || s == 302 || s == 303 || s == 307 || s == 308) &&
                            !location.empty();
    if (isRedirect && redirect == "error") {
      r.error = "Redirect is not allowed when redirect mode is 'error' (" +
                std::to_string(s) + " from " + url + ")";
      return r;
    }
    if (isRedirect && redirect != "manual") {
      if (hop >= 20) {
        r.error = "Too many redirects (20) starting at " + url;
        return r;
      }
      // Fetch spec 4.4: 303 (non-HEAD), and 301/302 after a POST, become a
      // body-less GET.
      if ((s == 303 && method != "HEAD") || ((s == 301 || s == 302) && method == "POST")) {
        method = "GET";
        body.clear();
        for (auto it = headers.begin(); it != headers.end();) {
          const auto k = lower(it->first);
          it = (k == "content-type" || k == "content-length") ? headers.erase(it) : ++it;
        }
      }
      url = resolveLocation(url, location);
      r.redirected = true;
      continue;
    }
    r.ok = true;
    r.status = s;
    r.statusText = res.statusText;
    r.url = url;
    r.headers = std::move(res.headers);
    r.body = std::move(res.body);
    return r;
  }
}

jsi::Value makeArrayBuffer(jsi::Runtime& rt, const std::string& bytes) {
  auto ctor = rt.global().getPropertyAsFunction(rt, "ArrayBuffer");
  auto obj = ctor.callAsConstructor(rt, static_cast<double>(bytes.size())).asObject(rt);
  auto ab = obj.getArrayBuffer(rt);
  if (!bytes.empty()) std::memcpy(ab.data(rt), bytes.data(), bytes.size());
  return jsi::Value(rt, obj);
}

std::string bytesOf(jsi::Runtime& rt, const jsi::Value& v) {
  if (!v.isObject() || !v.asObject(rt).isArrayBuffer(rt)) return {};
  auto ab = v.asObject(rt).getArrayBuffer(rt);
  return std::string(reinterpret_cast<const char*>(ab.data(rt)), ab.size(rt));
}

void deliver(jsi::Runtime& rt, double id, const FetchResult& r) {
  auto done = rt.global().getProperty(rt, "__rniExpoFetchDone");
  if (!done.isObject() || !done.asObject(rt).isFunction(rt)) return;
  auto fn = done.asObject(rt).asFunction(rt);
  if (!r.ok) {
    fn.call(rt, jsi::Value(id), jsi::Value(false), jsi::String::createFromUtf8(rt, r.error));
    return;
  }
  jsi::Object meta(rt);
  meta.setProperty(rt, "status", r.status);
  meta.setProperty(rt, "statusText", jsi::String::createFromUtf8(rt, r.statusText));
  meta.setProperty(rt, "url", jsi::String::createFromUtf8(rt, r.url));
  meta.setProperty(rt, "redirected", r.redirected);
  jsi::Array headers(rt, r.headers.size());
  size_t i = 0;
  for (const auto& [k, v] : r.headers) {
    jsi::Array pair(rt, 2);
    pair.setValueAtIndex(rt, 0, jsi::String::createFromUtf8(rt, k));
    pair.setValueAtIndex(rt, 1, jsi::String::createFromUtf8(rt, v));
    headers.setValueAtIndex(rt, i++, std::move(pair));
  }
  meta.setProperty(rt, "headers", std::move(headers));
  meta.setProperty(rt, "body", makeArrayBuffer(rt, r.body));
  fn.call(rt, jsi::Value(id), jsi::Value(true), std::move(meta));
}

using HostFn = std::function<jsi::Value(jsi::Runtime&, const jsi::Value*, size_t)>;
void addFn(jsi::Runtime& rt, jsi::Object& host, const char* name, unsigned argc, HostFn f) {
  host.setProperty(rt, name,
                   jsi::Function::createFromHostFunction(
                       rt, jsi::PropNameID::forAscii(rt, name), argc,
                       [f = std::move(f)](jsi::Runtime& rt, const jsi::Value&,
                                          const jsi::Value* a, size_t n) { return f(rt, a, n); }));
}

void installFetchHost(jsi::Runtime& rt, jsi::Object& host,
                      std::shared_ptr<react::CallInvoker> invoker,
                      std::shared_ptr<ExpoHostConfig> config,
                      std::shared_ptr<FetchState> state) {
  // start(id, url, method, [[k, v]...], redirect, ArrayBuffer|null)
  addFn(rt, host, "start", 6, [invoker, config, state](jsi::Runtime& rt, const jsi::Value* a,
                                                        size_t n) -> jsi::Value {
    if (n < 6 || !a[0].isNumber() || !a[1].isString()) {
      throw jsi::JSError(rt, "ExpoFetchModule start: bad arguments");
    }
    const double id = a[0].asNumber();
    std::string url = a[1].asString(rt).utf8(rt);
    std::string method = a[2].isString() ? a[2].asString(rt).utf8(rt) : "GET";
    std::string redirect = a[4].isString() ? a[4].asString(rt).utf8(rt) : "follow";
    std::map<std::string, std::string> headers;
    if (a[3].isObject() && a[3].asObject(rt).isArray(rt)) {
      auto arr = a[3].asObject(rt).asArray(rt);
      for (size_t i = 0; i < arr.size(rt); ++i) {
        auto pair = arr.getValueAtIndex(rt, i).asObject(rt).asArray(rt);
        const auto k = pair.getValueAtIndex(rt, 0).toString(rt).utf8(rt);
        const auto v = pair.getValueAtIndex(rt, 1).toString(rt).utf8(rt);
        auto& slot = headers[k];
        slot = slot.empty() ? v : slot + ", " + v;
      }
    }
    std::string body = bytesOf(rt, a[5]);
    auto network = config->network;
    if (network) network->inFlight.fetch_add(1);
    std::thread([=, url = std::move(url), method = std::move(method),
                 headers = std::move(headers), body = std::move(body)]() mutable {
      auto result = std::make_shared<FetchResult>(
          runFetch(std::move(url), std::move(method), std::move(headers), std::move(body),
                   redirect));
      invoker->invokeAsync([id, result, state](jsi::Runtime& rt) {
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          if (state->cancelled.erase(id) > 0) return;  // aborted: publish nothing
        }
        deliver(rt, id, *result);
      });
      if (network) {
        network->completed.fetch_add(1);
        network->inFlight.fetch_sub(1);
      }
    }).detach();
    return jsi::Value::undefined();
  });
  addFn(rt, host, "cancel", 1, [state](jsi::Runtime&, const jsi::Value* a, size_t n) {
    if (n > 0 && a[0].isNumber()) {
      std::lock_guard<std::mutex> lock(state->mutex);
      state->cancelled.insert(a[0].asNumber());
    }
    return jsi::Value::undefined();
  });
  addFn(rt, host, "utf8", 1, [](jsi::Runtime& rt, const jsi::Value* a, size_t n) -> jsi::Value {
    return jsi::String::createFromUtf8(rt, n > 0 ? bytesOf(rt, a[0]) : std::string());
  });
  addFn(rt, host, "createBlob", 1, [state](jsi::Runtime& rt, const jsi::Value* a,
                                           size_t n) -> jsi::Value {
    const std::string id = expoUuidv4();
    std::lock_guard<std::mutex> lock(state->mutex);
    state->blobs[id] = n > 0 ? bytesOf(rt, a[0]) : std::string();
    return jsi::String::createFromUtf8(rt, id);
  });
}

}  // namespace

void registerExpoFetch(ExpoModuleRegistry& registry, std::shared_ptr<ExpoHostConfig> config) {
  ExpoModuleDef def;
  def.js = kExpoFetchJs;
  auto state = std::make_shared<FetchState>();
  def.installHost = [config, state](jsi::Runtime& rt, jsi::Object& host,
                                    std::shared_ptr<react::CallInvoker> invoker) {
    installFetchHost(rt, host, std::move(invoker), config, state);
  };
  registry.add("ExpoFetchModule", std::move(def));
}

}  // namespace rni
