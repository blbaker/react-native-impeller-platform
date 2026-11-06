// WebHelperLink: the engine's end of the rni-webhelper connection (Linux/POSIX).
// Listens on a private socket, spawns the helper command, accepts it, and runs
// one IO thread that receives messages (with SCM_RIGHTS fds). Sends from any
// thread; anything sent before the helper connects is queued, in order.
#pragma once

#include <sys/types.h>

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "webview/WebViewProtocol.h"

namespace rni {

class WebHelperLink {
 public:
  using OnMessage = std::function<void(webproto::Message& m)>;  // IO thread
  using OnDown = std::function<void(const std::string& why)>;   // IO thread, once

  ~WebHelperLink();
  // Resolves the helper command. False (with why) when there is none.
  static bool Resolve(std::string* command, std::string* why);
  bool Start(OnMessage onMessage, OnDown onDown, std::string* error);
  void Send(const std::string& bytes);
  // Engine exit: kQuit after every command already sent, then reap the helper
  // within budgetMs (a hang-up and 1 s more if it ignores kQuit) and print
  // `rn-impeller: webview_helper_exit ...`. Idempotent; later sends are dropped.
  void Stop(int budgetMs);
  bool started() const { return started_; }
  bool down() const { return down_; }

 private:
  void Run();
  bool AcceptHelper();
  void Fail(const std::string& why);
  void JoinIo();

  OnMessage onMessage_;
  OnDown onDown_;
  std::string dir_, sockPath_;
  int listenFd_ = -1, fd_ = -1;
  int wake_[2] = {-1, -1};
  pid_t child_ = -1;
  std::thread io_;
  std::mutex sendMu_;
  std::vector<std::string> queue_;
  bool connected_ = false;
  std::atomic<bool> started_{false}, down_{false};
  std::atomic<bool> closing_{false};  // Stop() running: the helper's hang-up is expected
  bool stopped_ = false;
};

}  // namespace rni
