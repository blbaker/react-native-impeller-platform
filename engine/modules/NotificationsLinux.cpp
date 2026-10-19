// Linux notifications: org.freedesktop.Notifications over the session bus,
// through sd-bus loaded at runtime (see SdBus.h for why it is not linked).
//
// One worker thread owns the bus connection. sd-bus objects are not thread
// safe, so every call (Notify, GetCapabilities) and every signal callback runs
// on that thread, and the id maps below need no lock. The JS thread only
// queues work and is never blocked by a slow or hung notification server.
#include "modules/Notifications.h"
#include "modules/SdBus.h"

#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <deque>
#include <mutex>
#include <thread>
#include <unordered_map>

namespace rni::notifications {

namespace {

using sdbus::sd_bus;
using sdbus::sd_bus_error;
using sdbus::sd_bus_message;

constexpr const char* kName = "org.freedesktop.Notifications";
constexpr const char* kPath = "/org/freedesktop/Notifications";
constexpr const char* kIface = "org.freedesktop.Notifications";
constexpr uint32_t kClosedExpired = 1;  // spec: closed because it timed out

class LinuxBackend : public Backend {
 public:
  explicit LinuxBackend(PressSink onPress)
      : onPress_(std::move(onPress)), app_(AppDisplayName()) {
    if (pipe2(wake_, O_CLOEXEC | O_NONBLOCK) != 0) wake_[0] = wake_[1] = -1;
    worker_ = std::thread([this] { run(); });
  }

  ~LinuxBackend() override {
    {
      std::lock_guard<std::mutex> lock(mu_);
      stop_ = true;
    }
    wake();
    worker_.join();
    if (wake_[0] >= 0) close(wake_[0]);
    if (wake_[1] >= 0) close(wake_[1]);
  }

  void requestPermission(Done done) override {
    post([this, done = std::move(done)] { done(permissionNow()); });
  }

  void show(const Request& request, Done done) override {
    post([this, request, done = std::move(done)] { done(showNow(request)); });
  }

 private:
  struct Entry {
    std::string id;
    std::string data;
  };

  static const sdbus::Api& api() { return sdbus::Load(); }

  void post(std::function<void()> task) {
    {
      std::lock_guard<std::mutex> lock(mu_);
      tasks_.push_back(std::move(task));
    }
    wake();
  }

  void wake() {
    if (wake_[1] < 0) return;
    const char c = 1;
    // A full pipe already guarantees a wakeup, so a short write is fine.
    if (write(wake_[1], &c, 1) < 0 && errno != EAGAIN) {
      std::fprintf(stderr, "rn-impeller: notifications wake failed: %s\n",
                   std::strerror(errno));
    }
  }

  void run() {
    for (;;) {
      std::deque<std::function<void()>> batch;
      {
        std::lock_guard<std::mutex> lock(mu_);
        if (stop_) break;
        batch.swap(tasks_);
      }
      for (auto& task : batch) task();
      if (bus_ != nullptr) {
        int r = 0;
        while ((r = api().process(bus_, nullptr)) > 0) continue;
        if (r < 0) disconnect();  // the next call reconnects
      }
      waitForWork();
    }
    // Tasks still queued are dropped unanswered: the engine is shutting down
    // and their Promises die with the JS runtime.
    disconnect();
  }

  void waitForWork() {
    pollfd fds[2];
    nfds_t n = 0;
    int timeoutMs = 100;  // only used when the wake pipe could not be created
    if (wake_[0] >= 0) {
      fds[n++] = {wake_[0], POLLIN, 0};
      timeoutMs = -1;
    }
    if (bus_ != nullptr) {
      fds[n++] = {api().get_fd(bus_), (short)api().get_events(bus_), 0};
      uint64_t until = 0;
      if (api().get_timeout(bus_, &until) >= 0 && until != UINT64_MAX) {
        timespec ts{};
        clock_gettime(CLOCK_MONOTONIC, &ts);
        const uint64_t now = (uint64_t)ts.tv_sec * 1000000u + ts.tv_nsec / 1000;
        const int ms = until > now ? (int)((until - now + 999) / 1000) : 0;
        timeoutMs = timeoutMs < 0 ? ms : std::min(timeoutMs, ms);
      }
    }
    poll(fds, n, timeoutMs);
    char buf[64];
    while (wake_[0] >= 0 && read(wake_[0], buf, sizeof(buf)) > 0) continue;
  }

  bool connect(std::string& why) {
    if (bus_ != nullptr) return true;
    const auto& a = api();
    if (!a.ok) {
      why = a.error;
      return false;
    }
    sd_bus* bus = nullptr;
    int r = a.open_user(&bus);
    if (r < 0 || bus == nullptr) {
      why = std::string("no D-Bus session bus (") + std::strerror(-r) + ")";
      return false;
    }
    if (a.set_method_call_timeout != nullptr) {
      a.set_method_call_timeout(bus, 5u * 1000u * 1000u);
    }
    // ⛔ THE SENDER IS PINNED TO THE NOTIFICATION SERVER'S NAME.
    // ActionInvoked is a broadcast signal, so any client on the session bus
    // can emit one with our notification's id. With a null sender this
    // process would treat that as a click. The bus daemon resolves the
    // well-known name to its current owner and routes only that owner's
    // signals here.
    r = a.match_signal(bus, nullptr, kName, kPath, kIface, "ActionInvoked",
                       &LinuxBackend::onActionInvoked, this);
    if (r >= 0) {
      r = a.match_signal(bus, nullptr, kName, kPath, kIface,
                         "NotificationClosed", &LinuxBackend::onClosed, this);
    }
    if (r < 0) {
      a.flush_close_unref(bus);
      why = std::string("could not subscribe to notification signals (") +
            std::strerror(-r) + ")";
      return false;
    }
    bus_ = bus;
    return true;
  }

  void disconnect() {
    if (bus_ == nullptr) return;
    api().flush_close_unref(bus_);
    bus_ = nullptr;
    // D-Bus ids belong to the old connection's server session.
    byBusId_.clear();
    byJsId_.clear();
  }

  Result fromError(const sd_bus_error& err, int r) {
    const std::string name = err.name ? err.name : "";
    const std::string message = err.message ? err.message : std::strerror(-r);
    if (name == "org.freedesktop.DBus.Error.ServiceUnknown" ||
        name == "org.freedesktop.DBus.Error.NameHasNoOwner") {
      return {"unavailable",
              "no notification server owns org.freedesktop.Notifications on "
              "the session bus"};
    }
    if (name.empty() && (r == -ENOTCONN || r == -ECONNRESET)) {
      disconnect();
      return {"unavailable", "the session bus connection closed (" + message + ")"};
    }
    return {"error", (name.empty() ? std::string() : name + ": ") + message};
  }

  // freedesktop has no permission model: a reachable server is "granted".
  Result permissionNow() {
    std::string why;
    if (!connect(why)) return {"unavailable", why};
    sd_bus_error err{nullptr, nullptr, 0};
    sd_bus_message* reply = nullptr;
    const int r = api().call_method(bus_, kName, kPath, kIface,
                                    "GetCapabilities", &err, &reply, nullptr);
    Result res = r < 0 ? fromError(err, r) : Result{"granted", ""};
    if (reply != nullptr) api().message_unref(reply);
    api().error_free(&err);
    return res;
  }

  Result showNow(const Request& q) {
    std::string why;
    if (!connect(why)) return {"unavailable", why};
    uint32_t replaces = 0;
    if (auto it = byJsId_.find(q.id); it != byJsId_.end()) replaces = it->second;
    sd_bus_error err{nullptr, nullptr, 0};
    sd_bus_message* reply = nullptr;
    // Notify(app_name, replaces_id, app_icon, summary, body, actions, hints,
    // expire_timeout). "default" is the action key servers invoke for a click
    // on the notification body.
    const int r = api().call_method(
        bus_, kName, kPath, kIface, "Notify", &err, &reply, "susssasa{sv}i",
        app_.c_str(), replaces, "", q.title.c_str(), q.body.c_str(), 2u,
        "default", "Open", 0u, (int32_t)-1);
    Result res;
    uint32_t busId = 0;
    if (r < 0) {
      res = fromError(err, r);
    } else if (api().message_read(reply, "u", &busId) < 0) {
      res = {"error", "Notify replied without a notification id"};
    } else {
      if (replaces != 0 && replaces != busId) byBusId_.erase(replaces);
      byBusId_[busId] = Entry{q.id, q.data};
      byJsId_[q.id] = busId;
      res = {"shown", ""};
    }
    if (reply != nullptr) api().message_unref(reply);
    api().error_free(&err);
    return res;
  }

  static int onActionInvoked(sd_bus_message* m, void* userdata, sd_bus_error*) {
    auto* self = static_cast<LinuxBackend*>(userdata);
    uint32_t busId = 0;
    const char* action = nullptr;
    if (api().message_read(m, "us", &busId, &action) < 0 || action == nullptr) {
      return 0;
    }
    // ⛔ ONLY IDS THIS PROCESS SHOWED. The server broadcasts ActionInvoked for
    // every client's notifications, so a click on another app's notification
    // arrives here too, with the server as its legitimate sender.
    auto it = self->byBusId_.find(busId);
    const bool ours = it != self->byBusId_.end();
    std::printf("rn-impeller: notifications action_invoked bus_id=%u action=%s ours=%d\n",
                busId, action, ours ? 1 : 0);
    std::fflush(stdout);
    if (!ours || std::strcmp(action, "default") != 0) return 0;
    if (self->onPress_) self->onPress_(Press{it->second.id, it->second.data, "default"});
    return 0;
  }

  static int onClosed(sd_bus_message* m, void* userdata, sd_bus_error*) {
    auto* self = static_cast<LinuxBackend*>(userdata);
    uint32_t busId = 0;
    uint32_t reason = 0;
    if (api().message_read(m, "uu", &busId, &reason) < 0) return 0;
    // An expired popup can still sit in the server's history and be clicked
    // later, so only a dismissal or an explicit close forgets the id.
    if (reason == kClosedExpired) return 0;
    auto it = self->byBusId_.find(busId);
    if (it == self->byBusId_.end()) return 0;
    auto js = self->byJsId_.find(it->second.id);
    if (js != self->byJsId_.end() && js->second == busId) self->byJsId_.erase(js);
    self->byBusId_.erase(it);
    return 0;
  }

  PressSink onPress_;
  const std::string app_;
  int wake_[2] = {-1, -1};
  std::mutex mu_;
  std::deque<std::function<void()>> tasks_;
  bool stop_ = false;
  std::thread worker_;
  // Worker thread only.
  sd_bus* bus_ = nullptr;
  std::unordered_map<uint32_t, Entry> byBusId_;
  std::unordered_map<std::string, uint32_t> byJsId_;
};

}  // namespace

std::unique_ptr<Backend> CreateBackend(PressSink onPress) {
  return std::make_unique<LinuxBackend>(std::move(onPress));
}

}  // namespace rni::notifications
