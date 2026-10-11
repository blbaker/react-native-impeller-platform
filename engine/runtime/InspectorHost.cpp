// parity item 24 -- see InspectorHost.h for the design and threading.
#include "runtime/InspectorHost.h"

#include <jsinspector-modern/InspectorInterfaces.h>
#include <cxxreact/ReactNativeVersion.h>

#include <boost/asio/io_context.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/post.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/websocket.hpp>

#include <atomic>
#include <cstdio>
#include <deque>

#if !defined(_WIN32)
#include <unistd.h>
#endif

#include "modules/NetworkingModule.h"

namespace rni {

namespace jsi_m = facebook::react::jsinspector_modern;
namespace asio = boost::asio;
namespace beast = boost::beast;
namespace websocket = beast::websocket;
using tcp = asio::ip::tcp;

// ------------------------------------------------------------------------
// InspectorQueue

InspectorQueue::InspectorQueue() : thread_([this] { loop(); }) {}

InspectorQueue::~InspectorQueue() { stop(); }

void InspectorQueue::stop() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (quit_ && !thread_.joinable()) return;
    quit_ = true;
  }
  cv_.notify_all();
  if (thread_.joinable() && std::this_thread::get_id() != thread_.get_id()) {
    thread_.join();
  }
  std::multimap<std::chrono::steady_clock::time_point, std::function<void()>> drop;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    drop.swap(tasks_);
  }
}

bool InspectorQueue::onQueue() const {
  return std::this_thread::get_id() == thread_.get_id();
}

void InspectorQueue::post(std::function<void()> fn,
                          std::chrono::milliseconds delay) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (quit_) return;
    tasks_.emplace(std::chrono::steady_clock::now() + delay, std::move(fn));
  }
  cv_.notify_all();
}

void InspectorQueue::runSync(const std::function<void()>& fn) {
  if (onQueue()) {
    fn();
    return;
  }
  std::mutex m;
  std::condition_variable cv;
  bool done = false;
  post([&] {
    fn();
    std::lock_guard<std::mutex> l(m);
    done = true;
    cv.notify_all();
  });
  std::unique_lock<std::mutex> l(m);
  // Bounded: a queue that was stopped never runs the task.
  cv.wait_for(l, std::chrono::seconds(5), [&] { return done; });
}

void InspectorQueue::loop() {
  std::unique_lock<std::mutex> lock(mutex_);
  while (!quit_) {
    if (tasks_.empty()) {
      cv_.wait(lock);
      continue;
    }
    auto it = tasks_.begin();
    if (it->first > std::chrono::steady_clock::now()) {
      cv_.wait_until(lock, it->first);
      continue;
    }
    auto fn = std::move(it->second);
    tasks_.erase(it);
    lock.unlock();
    fn();
    lock.lock();
  }
}

// ------------------------------------------------------------------------
// The device socket: Beast ws:// client, one io thread, events hopped onto
// the inspector queue (IWebSocketDelegate's contract).

namespace {

class BeastInspectorSocket final
    : public jsi_m::IWebSocket,
      public std::enable_shared_from_this<BeastInspectorSocket> {
 public:
  struct State {
    asio::io_context ioc;
    tcp::resolver resolver{ioc};
    websocket::stream<beast::tcp_stream> ws{ioc};
    beast::flat_buffer buffer;
    std::deque<std::string> outbox;
    bool writing{false};
    bool open{false};
    std::atomic<bool> closed{false};
    std::weak_ptr<jsi_m::IWebSocketDelegate> delegate;
    std::shared_ptr<InspectorQueue> queue;
    std::thread thread;
  };

  BeastInspectorSocket(const std::string& url,
                       std::weak_ptr<jsi_m::IWebSocketDelegate> delegate,
                       std::shared_ptr<InspectorQueue> queue)
      : s_(std::make_shared<State>()) {
    s_->delegate = std::move(delegate);
    s_->queue = std::move(queue);
    start(url);
  }

  // IWebSocket: "If still connected when destroyed, the socket MUST
  // automatically send an end of session message and disconnect."
  ~BeastInspectorSocket() override {
    auto s = s_;
    s->closed = true;
    asio::post(s->ioc, [s] {
      beast::error_code ec;
      if (s->open) {
        s->ws.async_close(websocket::close_code::normal,
                          [s](beast::error_code) { s->ioc.stop(); });
      } else {
        beast::get_lowest_layer(s->ws).socket().close(ec);
        s->ioc.stop();
      }
    });
    if (s->thread.joinable()) {
      // Give the close frame a moment, then force.
      auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
      while (!s->ioc.stopped() && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
      s->ioc.stop();
      s->thread.join();
    }
  }

  void send(std::string_view message) override {
    auto s = s_;
    asio::post(s->ioc, [s, m = std::string(message)]() mutable {
      s->outbox.push_back(std::move(m));
      flush(s);
    });
  }

 private:
  static void deliver(const std::shared_ptr<State>& s,
                      std::function<void(jsi_m::IWebSocketDelegate&)> fn) {
    if (s->closed) return;
    s->queue->post([s, fn = std::move(fn)] {
      if (s->closed) return;
      if (auto d = s->delegate.lock()) fn(*d);
    });
  }

  static void fail(const std::shared_ptr<State>& s, const std::string& why) {
    if (s->closed.exchange(true)) return;
    // closed=true stops later events; deliver this one explicitly.
    s->queue->post([s, why] {
      if (auto d = s->delegate.lock()) d->didFailWithError(std::nullopt, why);
    });
    s->ioc.stop();
  }

  static void flush(const std::shared_ptr<State>& s) {
    if (s->writing || s->outbox.empty() || !s->open) return;
    s->writing = true;
    s->ws.text(true);
    s->ws.async_write(asio::buffer(s->outbox.front()),
                      [s](beast::error_code ec, std::size_t) {
                        s->writing = false;
                        if (ec) return fail(s, "write: " + ec.message());
                        s->outbox.pop_front();
                        flush(s);
                      });
  }

  static void readNext(const std::shared_ptr<State>& s) {
    s->ws.async_read(s->buffer, [s](beast::error_code ec, std::size_t) {
      if (ec == websocket::error::closed) {
        if (!s->closed.exchange(true)) {
          s->queue->post([s] {
            if (auto d = s->delegate.lock()) d->didClose();
          });
        }
        s->ioc.stop();
        return;
      }
      if (ec) return fail(s, "read: " + ec.message());
      std::string msg = beast::buffers_to_string(s->buffer.data());
      s->buffer.consume(s->buffer.size());
      deliver(s, [msg = std::move(msg)](jsi_m::IWebSocketDelegate& d) {
        d.didReceiveMessage(msg);
      });
      readNext(s);
    });
  }

  void start(const std::string& url) {
    auto s = s_;
    // ws://host:port/path?query  (http(s) mapped like the WebSocketModule)
    std::string u = url;
    if (u.rfind("http://", 0) == 0) u = "ws://" + u.substr(7);
    if (u.rfind("ws://", 0) != 0) {
      fail(s, "inspector socket: only ws:// is supported: " + url);
      return;
    }
    std::string rest = u.substr(5);
    const size_t slash = rest.find('/');
    const std::string hostport = slash == std::string::npos ? rest : rest.substr(0, slash);
    const std::string target = slash == std::string::npos ? "/" : rest.substr(slash);
    std::string host = hostport, port = "80";
    if (auto c = hostport.rfind(':'); c != std::string::npos) {
      host = hostport.substr(0, c);
      port = hostport.substr(c + 1);
    }
    const std::string hostHeader = hostport;
    s->resolver.async_resolve(
        host, port,
        [s, hostHeader, target](beast::error_code ec,
                                tcp::resolver::results_type results) {
          if (ec) return fail(s, "resolve: " + ec.message());
          beast::get_lowest_layer(s->ws).expires_after(std::chrono::seconds(10));
          beast::get_lowest_layer(s->ws).async_connect(
              results, [s, hostHeader, target](beast::error_code ec2, tcp::endpoint) {
                if (ec2) return fail(s, "connect: " + ec2.message());
                beast::get_lowest_layer(s->ws).expires_never();
                s->ws.set_option(websocket::stream_base::timeout::suggested(
                    beast::role_type::client));
                s->ws.read_message_max(64 * 1024 * 1024);
                s->ws.async_handshake(hostHeader, target, [s](beast::error_code ec3) {
                  if (ec3) return fail(s, "handshake: " + ec3.message());
                  s->open = true;
                  deliver(s, [](jsi_m::IWebSocketDelegate& d) { d.didOpen(); });
                  readNext(s);
                  flush(s);
                });
              });
        });
    s->thread = std::thread([s] {
      try {
        s->ioc.run();
      } catch (const std::exception& e) {
        fail(s, e.what());
      }
    });
  }

  std::shared_ptr<State> s_;
};

class PackagerDelegate final : public jsi_m::InspectorPackagerConnectionDelegate {
 public:
  explicit PackagerDelegate(std::shared_ptr<InspectorQueue> q) : queue_(std::move(q)) {}
  std::unique_ptr<jsi_m::IWebSocket> connectWebSocket(
      const std::string& url,
      std::weak_ptr<jsi_m::IWebSocketDelegate> delegate) override {
    std::printf("rn-impeller: inspector device socket -> %s\n", url.c_str());
    std::fflush(stdout);
    return std::make_unique<BeastInspectorSocket>(url, std::move(delegate), queue_);
  }
  void scheduleCallback(std::function<void(void)> callback,
                        std::chrono::milliseconds delayMs) override {
    queue_->post(std::move(callback), delayMs);
  }

 private:
  std::shared_ptr<InspectorQueue> queue_;
};

std::string urlEncode(const std::string& s) {
  static const char* hex = "0123456789ABCDEF";
  std::string out;
  for (unsigned char c : s) {
    if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
      out.push_back((char)c);
    } else {
      out.push_back('%');
      out.push_back(hex[c >> 4]);
      out.push_back(hex[c & 15]);
    }
  }
  return out;
}

std::string hostName() {
#if !defined(_WIN32)
  char buf[256] = {0};
  if (gethostname(buf, sizeof(buf) - 1) == 0 && buf[0]) return buf;
#endif
  return "desktop";
}

}  // namespace

// ------------------------------------------------------------------------
// InspectorHost

InspectorHost::InspectorHost(ReloadHook reload)
    : queue_(std::make_shared<InspectorQueue>()), reload_(std::move(reload)) {
  // HostTarget must be created and destroyed on the inspector queue.
  queue_->runSync([this] {
    std::weak_ptr<InspectorQueue> wq = queue_;
    hostTarget_ = jsi_m::HostTarget::create(*this, [wq](std::function<void()>&& cb) {
      if (auto q = wq.lock()) q->post(std::move(cb));
    });
    std::weak_ptr<jsi_m::HostTarget> weakTarget = hostTarget_;
    pageId_ = jsi_m::getInspectorInstance().addPage(
        "React Native Bridgeless", /*vm*/ "",
        [weakTarget](std::unique_ptr<jsi_m::IRemoteConnection> remote)
            -> std::unique_ptr<jsi_m::ILocalConnection> {
          auto t = weakTarget.lock();
          if (!t) return nullptr;
          std::printf("rn-impeller: inspector session connected\n");
          std::fflush(stdout);
          return t->connect(std::move(remote));
        },
        {.nativePageReloads = true});
  });
  std::printf("rn-impeller: inspector host up page=%d\n", pageId_ ? *pageId_ : -1);
  std::fflush(stdout);
}

InspectorHost::~InspectorHost() { shutdown(); }

void InspectorHost::connectToMetro(const std::string& sourceUrl,
                                   const std::string& appName) {
  const bool http = sourceUrl.rfind("http://", 0) == 0;
  if (!http) return;  // https needs TLS; file:// has no Metro
  appName_ = appName;
  const std::string rest = sourceUrl.substr(7);
  const size_t slash = rest.find('/');
  const std::string hostport = slash == std::string::npos ? rest : rest.substr(0, slash);
  const std::string device = hostName();
  const std::string url = "ws://" + hostport + "/inspector/device?name=" +
                          urlEncode(device) + "&app=" + urlEncode(appName) +
                          "&device=" + urlEncode("rn-impeller-" + device + "-" + appName) +
                          "&profiling=false";
  queue_->runSync([this, url, device, appName] {
    packager_ = std::make_unique<jsi_m::InspectorPackagerConnection>(
        url, device, appName, std::make_unique<PackagerDelegate>(queue_));
    packager_->connect();
  });
}

void InspectorHost::shutdown() {
  if (shutDown_) return;
  shutDown_ = true;
  queue_->runSync([this] {
    if (packager_) {
      packager_->closeQuietly();
      packager_.reset();  // destroys sessions -> releases HostTarget refs
    }
    if (pageId_) {
      jsi_m::getInspectorInstance().removePage(*pageId_);
      pageId_.reset();
    }
    hostTarget_.reset();
  });
  queue_->stop();
}

jsi_m::HostTargetMetadata InspectorHost::getMetadata() {
  const auto& v = facebook::react::ReactNativeVersion;
  jsi_m::HostTargetMetadata m;
  m.appDisplayName = appName_;
  m.appIdentifier = appName_;
  m.deviceName = hostName();
  m.integrationName = "react-native-impeller";
#if defined(__APPLE__)
  m.platform = "impeller-macos";
#elif defined(_WIN32)
  m.platform = "impeller-windows";
#else
  m.platform = "impeller-linux";
#endif
  m.reactNativeVersion = std::to_string(v.Major) + "." + std::to_string(v.Minor) +
                         "." + std::to_string(v.Patch);
  return m;
}

void InspectorHost::onReload(const PageReloadRequest&) {
  std::printf("rn-impeller: inspector reload requested\n");
  std::fflush(stdout);
  if (reload_ && *reload_) (*reload_)("inspector Page.reload");
}

void InspectorHost::onSetPausedInDebuggerMessage(
    const OverlaySetPausedInDebuggerMessageRequest& request) {
  std::printf("rn-impeller: debugger_overlay %s\n",
              request.message ? request.message->c_str() : "(hidden)");
  std::fflush(stdout);
}

void InspectorHost::loadNetworkResource(
    const jsi_m::LoadNetworkResourceRequest& params,
    jsi_m::ScopedExecutor<jsi_m::NetworkRequestListener> executor) {
  // Source maps / sources for the debugger, fetched over plain http (the
  // Metro that served the bundle). Done on a worker so the queue stays free.
  const std::string url = params.url;
  std::thread([url, executor = std::move(executor)]() mutable {
    ParsedUrl parsed = parseUrl(url);
    if (!parsed.valid) {
      executor([e = parsed.error](jsi_m::NetworkRequestListener& l) { l.onError(e); });
      return;
    }
    HttpResponse r = performRequest("GET", parsed, {}, "", 60000);
    if (!r.ok) {
      executor([e = r.error](jsi_m::NetworkRequestListener& l) { l.onError(e); });
      return;
    }
    executor([r = std::move(r)](jsi_m::NetworkRequestListener& l) {
      l.onHeaders((uint32_t)r.status, r.headers);
      l.onData(r.body);
      l.onCompletion();
    });
  }).detach();
}

}  // namespace rni
