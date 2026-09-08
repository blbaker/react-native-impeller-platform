// Networking — the TurboModule behind fetch() and XMLHttpRequest.
//
// ⛔ WHY THIS MODULE'S ABSENCE WAS INVISIBLE, AND WHY THE GATE ASSERTS TWO
// THINGS. RN's JS half of networking is complete without any native module:
// `whatwg-fetch` installs a global `fetch` that is a real function, and
// XMLHttpRequest.js imports cleanly. So `typeof fetch === 'function'` is TRUE
// on an engine with NO network stack whatsoever — it was true here for the
// entire life of the project. The only honest native-side signal is
// `TurboModuleRegistry.get('Networking')` being non-null AND a request
// actually completing. Same disease as AlertManager in P4: the JS can be
// perfect and the feature 100% broken.
//
// WHY BOOST.ASIO AND NOT NSURLSession
//
// The obvious darwin implementation is ObjC++ over NSURLSession, and it would
// be shorter. It would also only exist on darwin: this engine stages
// linux-x64 and win32-x64 packages too, so an ObjC++ module means writing the
// module three times and shipping an engine whose module manifest DIFFERS BY
// PLATFORM — which is precisely the thing the D7 registry exists to make
// impossible to do accidentally. Boost is already a dependency (header-only,
// fetched by cmake/ReactCommonDeps.cmake as `rc_boost`), so asio costs no new
// third_party entry. One TU, three platforms, one manifest.
//
// ⚠️ HTTP ONLY, AND IT SAYS SO OUT LOUD. There is no TLS here: OpenSSL is not
// vendored and asio's ssl layer needs it. An `https://` URL is REJECTED with
// an explicit error delivered through the normal completion event, so the JS
// promise rejects with a readable message. It does NOT silently hang, and it
// does NOT quietly downgrade to http. Adding TLS is a deliberate follow-up
// with a new third_party pin, not something to sneak in.
#pragma once

#include <FBReactNativeSpecJSI.h>

#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace rni {

namespace jsi = facebook::jsi;

// ⛔ "JS IS IDLE" IS NOT "THE NETWORK IS DONE", AND CONFLATING THEM CAPTURES
// THE FRAME TOO EARLY. A request runs on a native worker thread; while it is
// on the wire there is NO pending JS task, so JsThread::isIdle() is true and a
// headless run screenshots before a single response has landed. Measured: the
// first two P10 runs painted the native-half swatch green and every request
// swatch red, with no JS error — a working transport looking exactly like a
// dead one.
//
// So the host waits on this too. `completed` is also the native-side
// side-effect counter, the same role alerts_shown plays for AlertManager: the
// pixel proves JS got its response, this proves a request actually crossed
// into native and finished.
struct NetworkActivity {
  std::atomic<int> inFlight{0};
  std::atomic<int> completed{0};
};

// The parsed pieces of a request URL. `valid` is false when the URL is not
// something this module can execute, and `error` then carries the reason that
// JS will see.
struct ParsedUrl {
  bool valid{false};
  std::string error;
  std::string scheme;
  std::string host;
  std::string port;
  std::string target;  // path + query, always starts with '/'
};

// Splits an absolute http:// URL. Exposed (rather than static) because it is
// the piece with edge cases worth testing without a socket: default port,
// empty path, explicit port, and the https rejection.
ParsedUrl parseUrl(const std::string& url);

// A response as read off the wire, before it becomes JS values.
struct HttpResponse {
  bool ok{false};
  std::string error;          // non-empty iff ok == false
  int status{0};
  std::string statusText;
  std::map<std::string, std::string> headers;
  std::string body;
};

// Performs one blocking HTTP request. Pure I/O: no jsi, no runtime, no
// TurboModule — which is what lets it run on a worker thread and be exercised
// by `--test-http` without a JS runtime existing at all.
HttpResponse performRequest(const std::string& method,
                            const ParsedUrl& url,
                            const std::map<std::string, std::string>& headers,
                            const std::string& body,
                            double timeoutMs);

// Runs parseUrl over a table of URLs and prints one line per case. No socket
// is opened. This is the half of the module that can be gated on a build
// machine with no network.
int runUrlSelfTest();

// Starts a loopback HTTP server on an ephemeral port, drives a real GET and a
// real POST-with-headers through performRequest, and asserts the server saw
// what JS asked for. Returns 0 on success. This is the end-to-end proof that
// the transport works, independent of the RN runtime.
int runHttpSelfTest();

class NetworkingModule
    : public facebook::react::NativeNetworkingIOSCxxSpec<NetworkingModule> {
 public:
  NetworkingModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                   std::shared_ptr<NetworkActivity> activity)
      : NativeNetworkingIOSCxxSpec(std::move(jsInvoker)),
        activity_(std::move(activity)) {}

  ~NetworkingModule() override;

  // ⛔ THE CALLBACK IS THE REQUEST ID HANDSHAKE, AND IT MUST FIRE BEFORE ANY
  // EVENT. XMLHttpRequest.js stores the id from this callback and then matches
  // incoming events against it; an event carrying an id JS has not yet seen is
  // dropped on the floor. So the id is allocated and handed back
  // SYNCHRONOUSLY, and only then does the worker thread start.
  void sendRequest(jsi::Runtime& rt, jsi::Object query, jsi::Function callback);

  void abortRequest(jsi::Runtime& rt, double requestId);
  void clearCookies(jsi::Runtime& rt, jsi::Function callback);

  // Events reach JS through TurboModule::emitDeviceEvent, so the RN-standard
  // addListener/removeListeners are bookkeeping only — RCTNetworking.js
  // subscribes on RCTDeviceEventEmitter directly, not through us.
  void addListener(jsi::Runtime&, jsi::String) {}
  void removeListeners(jsi::Runtime&, double) {}

 private:
  void emitResponse(double requestId,
                    int status,
                    const std::map<std::string, std::string>& headers,
                    const std::string& url);
  void emitData(double requestId, const std::string& body);
  void emitComplete(double requestId, const std::string& error, bool timedOut);

  std::atomic<double> nextRequestId_{1};

  // Shared with the host so a headless run can wait for the network rather
  // than only for the JS thread. See NetworkActivity.
  std::shared_ptr<NetworkActivity> activity_;

  // Aborted ids. A cancelled request's worker still runs to completion (asio's
  // blocking API gives no safe way to interrupt a socket mid-read from another
  // thread), so cancellation is enforced at the EMIT boundary: an aborted id
  // publishes nothing. That is observably identical to JS and cannot race a
  // half-destroyed socket.
  std::mutex mutex_;
  std::unordered_map<double, bool> aborted_;

  // Number of worker threads still running. ~NetworkingModule waits on this:
  // a worker calls emitDeviceEvent on `this`, so letting the module die with
  // threads in flight is a use-after-free on the JS thread's schedule.
  std::atomic<int> inFlight_{0};
};

}  // namespace rni
