// Desktop notifications: the platform seam under the "Notifications" module.
//
// One Backend per OS, chosen at build time by CMake:
//   Linux   NotificationsLinux.cpp   org.freedesktop.Notifications over D-Bus
//   macOS   NotificationsDarwin.mm   UNUserNotificationCenter
//   Windows NotificationsWin.cpp     WinRT toast notifications
//   other   NotificationsNull.cpp    always "unavailable"
//
// This header has no JSI or React Native types in it, on purpose. Each backend
// can then be compiled and driven on its own (the macOS and Windows backends
// were checked that way on hosts without a full engine build), and the
// TurboModule in NotificationsModule.h stays the only place that knows about
// Promises and threads.
//
// Contract every backend keeps:
//   - It never throws and never crashes the process. A missing OS service, a
//     missing library or an unbundled macOS binary is a Result with status
//     "unavailable" and a reason a person can act on.
//   - `done` is called exactly once per call, on any thread.
//   - The press sink is called on any thread, only for notifications this
//     process showed, and only for the default action (a click on the body).
#pragma once

#include <functional>
#include <memory>
#include <string>

namespace rni::notifications {

// status is one of:
//   requestPermission: "granted" | "denied" | "unavailable" | "error"
//   show:              "shown"   | "denied" | "unavailable" | "error"
struct Result {
  std::string status;
  std::string reason;
};

struct Request {
  std::string id;     // caller's id; showing the same id again replaces it
  std::string title;
  std::string body;
  std::string data;   // opaque to native (JSON from the JS side), echoed on press
};

struct Press {
  std::string id;
  std::string data;
  std::string action;  // "default"
};

using Done = std::function<void(Result)>;
using PressSink = std::function<void(const Press&)>;

class Backend {
 public:
  virtual ~Backend() = default;
  virtual void requestPermission(Done done) = 0;
  virtual void show(const Request& request, Done done) = 0;
};

// Defined once per platform (see the file list above).
std::unique_ptr<Backend> CreateBackend(PressSink onPress);

// The name shown as the sender: RNI_APP_NAME when set, else the executable's
// file name without extension. Shared by the Linux and Windows backends; macOS
// takes the name from the app bundle.
std::string AppDisplayName();

}  // namespace rni::notifications
