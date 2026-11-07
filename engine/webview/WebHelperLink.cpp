#include "webview/WebHelperLink.h"

#include <fcntl.h>
#include <poll.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

extern char** environ;

namespace rni {
namespace wp = webproto;
namespace {

std::string ExeDir() {
  char buf[4096];
  const ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
  if (n <= 0) return ".";
  buf[n] = 0;
  std::string p(buf);
  const size_t s = p.rfind('/');
  return s == std::string::npos ? "." : p.substr(0, s);
}

std::string ShellQuote(const std::string& s) {
  std::string o = "'";
  for (char c : s) o += c == '\'' ? std::string("'\\''") : std::string(1, c);
  return o + "'";
}

void MkdirP(const std::string& path) {
  std::string cur;
  for (size_t i = 0; i < path.size(); ++i) {
    cur += path[i];
    if ((path[i] == '/' && i > 0) || i + 1 == path.size()) mkdir(cur.c_str(), 0700);
  }
}

std::string DataDir() {
  if (const char* d = getenv("RNI_WEBVIEW_DATA_DIR"); d && *d) return d;
  if (const char* x = getenv("XDG_DATA_HOME"); x && *x) return std::string(x) + "/rn-impeller/webview";
  const char* home = getenv("HOME");
  return std::string(home ? home : "/tmp") + "/.local/share/rn-impeller/webview";
}

}  // namespace

bool WebHelperLink::Resolve(std::string* command, std::string* why) {
  if (const char* c = getenv("RNI_WEBHELPER"); c && *c) {
    *command = c;
    return true;
  }
  const std::string local = ExeDir() + "/rni-webhelper";
  if (access(local.c_str(), X_OK) == 0) {
    *command = ShellQuote(local);
    return true;
  }
  if (why) *why = "no web helper: set RNI_WEBHELPER or install rni-webhelper next to " + ExeDir();
  return false;
}

WebHelperLink::~WebHelperLink() { JoinIo(); }

void WebHelperLink::JoinIo() {
  if (wake_[1] >= 0) (void)!write(wake_[1], "x", 1);
  if (io_.joinable()) io_.join();
}

bool WebHelperLink::Start(OnMessage onMessage, OnDown onDown, std::string* error) {
  std::string command;
  if (!Resolve(&command, error)) return false;
  onMessage_ = std::move(onMessage);
  onDown_ = std::move(onDown);
  const char* tmp = getenv("TMPDIR");
  std::string tmpl = std::string(tmp && *tmp ? tmp : "/tmp") + "/rni-wv-XXXXXX";
  if (!mkdtemp(&tmpl[0])) { *error = "mkdtemp failed"; return false; }
  dir_ = tmpl;
  sockPath_ = dir_ + "/s";
  listenFd_ = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  if (sockPath_.size() >= sizeof addr.sun_path) { *error = "socket path too long"; return false; }
  memcpy(addr.sun_path, sockPath_.c_str(), sockPath_.size() + 1);
  if (listenFd_ < 0 || bind(listenFd_, (sockaddr*)&addr, sizeof addr) != 0 || listen(listenFd_, 1) != 0) {
    *error = std::string("web helper socket: ") + strerror(errno);
    return false;
  }
  if (pipe2(wake_, O_CLOEXEC) != 0) { *error = "pipe2 failed"; return false; }
  const std::string data = DataDir();
  MkdirP(data);
  const std::string line = command + " --socket " + ShellQuote(sockPath_) + " --data-dir " + ShellQuote(data);
  const char* argv[] = {"/bin/sh", "-c", line.c_str(), nullptr};
  if (posix_spawn(&child_, "/bin/sh", nullptr, nullptr, const_cast<char**>(argv), environ) != 0) {
    *error = "could not spawn the web helper: " + line;
    return false;
  }
  printf("rn-impeller: webview_helper_spawn pid=%d cmd=%s\n", (int)child_, line.c_str());
  fflush(stdout);
  started_ = true;
  io_ = std::thread([this] { Run(); });
  return true;
}

void WebHelperLink::Send(const std::string& bytes) {
  std::lock_guard<std::mutex> lock(sendMu_);
  if (down_) return;
  if (!connected_) {
    queue_.push_back(bytes);
    return;
  }
  if (send(fd_, bytes.data(), bytes.size(), MSG_NOSIGNAL) < 0)
    fprintf(stderr, "rn-impeller: webview send failed: %s\n", strerror(errno));
}

void WebHelperLink::Fail(const std::string& why) {
  {
    std::lock_guard<std::mutex> lock(sendMu_);
    if (down_) return;
    down_ = true;
    queue_.clear();
  }
  if (closing_) return;  // Stop() asked it to go: the hang-up is the reply, not a failure
  printf("rn-impeller: webview_helper_down reason=%s\n", why.c_str());
  fflush(stdout);
  if (onDown_) onDown_(why);
}

void WebHelperLink::Stop(int budgetMs) {
  if (!started_ || stopped_) return;
  stopped_ = true;
  closing_ = true;
  bool connected = false;
  {
    std::lock_guard<std::mutex> lock(sendMu_);
    connected = connected_ && !down_;
    // SEQPACKET keeps order: the helper runs every kDestroy before this kQuit.
    const std::string quit = wp::Writer(wp::kQuit, 0).bytes();
    if (connected) (void)send(fd_, quit.data(), quit.size(), MSG_NOSIGNAL);
  }
  if (!connected) {  // still accepting (or never got there): end that first, so ONE thread reaps
    JoinIo();
    if (listenFd_ >= 0) {
      close(listenFd_);
      listenFd_ = -1;
      unlink(sockPath_.c_str());
      rmdir(dir_.c_str());
    }
  }
  const pid_t pid = child_;  // connected (or IO joined): no other thread touches child_ now
  if (pid <= 0) {  // reaped before it connected; AcceptHelper printed why
    down_ = true;
    return;
  }
  int status = 0;
  pid_t r = 0;
  bool hungUp = false;
  const auto t0 = std::chrono::steady_clock::now();
  auto deadline = t0 + std::chrono::milliseconds(budgetMs);
  for (;;) {
    r = waitpid(pid, &status, WNOHANG);
    if (r != 0) break;  // reaped (== pid) or gone (-1)
    if (std::chrono::steady_clock::now() > deadline) {
      if (hungUp || fd_ < 0) break;
      shutdown(fd_, SHUT_RDWR);  // it ignored kQuit: hang up, as a bare engine exit would
      hungUp = true;
      deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1000);
    }
    usleep(10000);
  }
  JoinIo();
  down_ = true;
  const long ms = (long)std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now() - t0).count();
  if (r == pid) child_ = -1;
  if (r == pid && WIFEXITED(status))
    printf("rn-impeller: webview_helper_exit pid=%d code=%d ms=%ld%s\n", (int)pid,
           WEXITSTATUS(status), ms, hungUp ? " after_hangup=1" : "");
  else if (r == pid && WIFSIGNALED(status))
    printf("rn-impeller: webview_helper_exit pid=%d signal=%d core=%d ms=%ld\n", (int)pid,
           WTERMSIG(status), WCOREDUMP(status) ? 1 : 0, ms);
  else if (r == 0)
    printf("rn-impeller: webview_helper_exit pid=%d timeout_ms=%ld\n", (int)pid, ms);
  else
    printf("rn-impeller: webview_helper_exit pid=%d error=%s\n", (int)pid, strerror(errno));
  fflush(stdout);
}

bool WebHelperLink::AcceptHelper() {
  const char* ms = getenv("RNI_WEBHELPER_CONNECT_MS");
  const int budget = ms ? atoi(ms) : 30000;  // a cold docker start takes ~1-2 s
  const auto t0 = std::chrono::steady_clock::now();
  for (;;) {
    pollfd p[2] = {{listenFd_, POLLIN, 0}, {wake_[0], POLLIN, 0}};
    const int r = poll(p, 2, 100);
    if (r > 0 && (p[1].revents & POLLIN)) return false;
    if (r > 0 && (p[0].revents & POLLIN)) {
      fd_ = accept4(listenFd_, nullptr, nullptr, SOCK_CLOEXEC);
      if (fd_ >= 0) break;
    }
    int status = 0;
    if (child_ > 0 && waitpid(child_, &status, WNOHANG) == child_) {
      child_ = -1;
      Fail("helper exited before connecting (status " + std::to_string(WEXITSTATUS(status)) + ")");
      return false;
    }
    const auto ms_ = std::chrono::duration_cast<std::chrono::milliseconds>(
                         std::chrono::steady_clock::now() - t0).count();
    if (ms_ > budget) {
      Fail("helper did not connect within " + std::to_string(budget) + " ms");
      return false;
    }
  }
  close(listenFd_);
  listenFd_ = -1;
  unlink(sockPath_.c_str());
  rmdir(dir_.c_str());
  std::vector<std::string> q;
  {
    std::lock_guard<std::mutex> lock(sendMu_);
    connected_ = true;
    q.swap(queue_);
    for (auto& b : q) (void)send(fd_, b.data(), b.size(), MSG_NOSIGNAL);
  }
  printf("rn-impeller: webview_helper_connected queued=%zu\n", q.size());
  fflush(stdout);
  return true;
}

void WebHelperLink::Run() {
  if (!AcceptHelper()) return;
  std::string buf(wp::kMaxPacket, '\0');
  for (;;) {
    pollfd p[2] = {{fd_, POLLIN, 0}, {wake_[0], POLLIN, 0}};
    if (poll(p, 2, -1) < 0) continue;
    if (p[1].revents & POLLIN) return;
    iovec iov{&buf[0], buf.size()};
    alignas(cmsghdr) char ctl[CMSG_SPACE(sizeof(int))];
    msghdr msg{};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = ctl;
    msg.msg_controllen = sizeof ctl;
    const ssize_t n = recvmsg(fd_, &msg, MSG_CMSG_CLOEXEC);
    if (n <= 0) {
      Fail(n == 0 ? "helper closed the connection" : std::string("recvmsg: ") + strerror(errno));
      return;
    }
    wp::Message m;
    for (cmsghdr* c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c))
      if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) memcpy(&m.fd, CMSG_DATA(c), sizeof(int));
    if (!wp::Parse(buf.data(), (size_t)n, &m)) {
      if (m.fd >= 0) close(m.fd);
      fprintf(stderr, "rn-impeller: webview malformed packet (%zd bytes)\n", n);
      continue;
    }
    onMessage_(m);
  }
}

}  // namespace rni
