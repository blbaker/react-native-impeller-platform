// rni-webhelper main: connect to the engine's socket, run a GLib main loop,
// dispatch protocol messages to WPE views. One helper per engine process; all
// its views share ONE persistent network session (cookies, storage, cache), so
// a sign-in survives a page change and an app restart, and kClearData wipes it.
//
//   rni-webhelper --socket <path> --data-dir <dir> [--cache-dir <dir>]
//   rni-webhelper --version   (one line, exit 0: proves the image's WPE loads;
//                              rn-impeller --doctor runs it, linux matrix M7)
#include <glib-unix.h>
#include <wpe/headless/wpe-headless.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <string>

#include "helper.h"

namespace rniweb {
namespace wp = rni::webproto;

Helper& H() {
  static Helper h;
  return h;
}

void Send(const wp::Writer& w, int fd) {
  const std::string& b = w.bytes();
  if (b.size() > wp::kMaxPacket) {
    fprintf(stderr, "rni-webhelper: dropping oversized message (%zu bytes)\n", b.size());
    return;
  }
  iovec iov{const_cast<char*>(b.data()), b.size()};
  msghdr msg{};
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  alignas(cmsghdr) char ctl[CMSG_SPACE(sizeof(int))];
  if (fd >= 0) {
    msg.msg_control = ctl;
    msg.msg_controllen = sizeof ctl;
    cmsghdr* c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(c), &fd, sizeof fd);
  }
  if (sendmsg(H().sock, &msg, MSG_NOSIGNAL) < 0) perror("rni-webhelper: sendmsg");
}

std::string JsonEscape(const std::string& s) {
  std::string o = "\"";
  for (unsigned char c : s) {
    switch (c) {
      case '"': o += "\\\""; break;
      case '\\': o += "\\\\"; break;
      case '\n': o += "\\n"; break;
      case '\r': o += "\\r"; break;
      case '\t': o += "\\t"; break;
      default:
        if (c < 0x20) {
          char t[8];
          snprintf(t, sizeof t, "\\u%04x", c);
          o += t;
        } else {
          o += (char)c;
        }
    }
  }
  return o + "\"";
}

void SendEvent(uint32_t view, const std::string& type, const std::string& json) {
  if (H().log) printf("rni-webhelper: event view=%u %s %s\n", view, type.c_str(), json.c_str());
  Send(wp::Writer(wp::kEvent, view).str(type).str(json));
}

namespace {

View* Find(uint32_t id) {
  auto it = H().views.find(id);
  return it == H().views.end() ? nullptr : it->second.get();
}

void Dispatch(const wp::Message& m) {
  View* v = Find(m.view);
  switch (m.type) {
    case wp::kCreate:
      if (!v) H().views[m.view].reset(CreateView(m.view, (int)m.i(0), (int)m.i(1), m.d(2), m.s(3)));
      return;
    case wp::kQuit:
      g_main_loop_quit(H().loop);
      return;
    case wp::kClearData: {
      auto* dm = webkit_network_session_get_website_data_manager(H().session);
      webkit_website_data_manager_clear(
          dm, WEBKIT_WEBSITE_DATA_ALL, 0, nullptr,
          +[](GObject* src, GAsyncResult* res, gpointer) {
            GError* err = nullptr;
            const bool ok = webkit_website_data_manager_clear_finish(
                WEBKIT_WEBSITE_DATA_MANAGER(src), res, &err);
            SendEvent(0, "dataCleared",
                      std::string("{\"ok\":") + (ok ? "true" : "false") + ",\"error\":" +
                          JsonEscape(err ? err->message : "") + "}");
            if (err) g_error_free(err);
          },
          nullptr);
      return;
    }
    default:
      break;
  }
  if (!v) return;  // the view was destroyed; late input is not an error
  switch (m.type) {
    case wp::kLoad: LoadUrl(v, m.s(0), m.s(1)); break;
    case wp::kResize: {
      v->scale = m.d(2) > 0 ? m.d(2) : 1;
      WPEToplevel* top = wpe_view_get_toplevel(v->wpe);
      if (wpe_toplevel_get_scale(top) != v->scale) wpe_toplevel_scale_changed(top, v->scale);
      wpe_toplevel_resize(top, (int)m.i(0), (int)m.i(1));
      break;
    }
    case wp::kNav: {
      const std::string& a = m.s(0);
      if (a == "back") webkit_web_view_go_back(v->web);
      else if (a == "forward") webkit_web_view_go_forward(v->web);
      else if (a == "reload") webkit_web_view_reload(v->web);
      else if (a == "stop") webkit_web_view_stop_loading(v->web);
      break;
    }
    case wp::kInject:
      webkit_web_view_evaluate_javascript(v->web, m.s(0).c_str(), (gssize)m.s(0).size(), nullptr,
                                          nullptr, nullptr, nullptr, nullptr);
      break;
    case wp::kUserScript:
      (m.s(1) == "start" ? v->scriptStart : v->scriptEnd) = m.s(0);
      SetUserScripts(v);
      break;
    case wp::kPointer:
    case wp::kTouch:
    case wp::kScroll:
    case wp::kKey:
    case wp::kFocus:
    case wp::kText:
      HandleInput(v, m);
      break;
    case wp::kReleaseSlot: ReleaseSlot(v, (uint32_t)m.i(0), (int)m.i(1)); break;
    case wp::kDestroy:
      DestroyView(v);
      H().views.erase(m.view);
      break;
    default:
      fprintf(stderr, "rni-webhelper: unknown message type %u\n", m.type);
  }
}

gboolean OnSocket(gint fd, GIOCondition cond, gpointer) {
  static std::string buf(wp::kMaxPacket, '\0');
  if (cond & (G_IO_HUP | G_IO_ERR)) {
    g_main_loop_quit(H().loop);
    return G_SOURCE_REMOVE;
  }
  const ssize_t n = recv(fd, &buf[0], buf.size(), MSG_DONTWAIT);
  if (n == 0) {  // engine gone: nothing left to render for
    g_main_loop_quit(H().loop);
    return G_SOURCE_REMOVE;
  }
  if (n < 0) return G_SOURCE_CONTINUE;
  wp::Message m;
  if (!wp::Parse(buf.data(), (size_t)n, &m)) {
    fprintf(stderr, "rni-webhelper: malformed packet (%zd bytes)\n", n);
    return G_SOURCE_CONTINUE;
  }
  Dispatch(m);
  return G_SOURCE_CONTINUE;
}

std::string Arg(int argc, char** argv, const char* name, const char* def = "") {
  for (int i = 1; i + 1 < argc; ++i)
    if (strcmp(argv[i], name) == 0) return argv[i + 1];
  return def;
}

}  // namespace
}  // namespace rniweb

int main(int argc, char** argv) {
  using namespace rniweb;
  setvbuf(stdout, nullptr, _IOLBF, 0);
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    // Reaching main at all means the dynamic loader resolved WebKit, WPEPlatform
    // and everything they NEED. Runtime version first, then the headers'.
    printf("rni-webhelper: version webkit=%u.%u.%u built=%d.%d.%d eme=%d\n",
           webkit_get_major_version(), webkit_get_minor_version(), webkit_get_micro_version(),
           WEBKIT_MAJOR_VERSION, WEBKIT_MINOR_VERSION, WEBKIT_MICRO_VERSION,
#if defined(RNI_WEBHELPER_EME)
           1);
#else
           0);
#endif
    return 0;
  }
  const std::string sockPath = Arg(argc, argv, "--socket");
  const std::string dataDir = Arg(argc, argv, "--data-dir");
  std::string cacheDir = Arg(argc, argv, "--cache-dir");
  if (sockPath.empty() || dataDir.empty()) {
    fprintf(stderr, "usage: rni-webhelper --socket <path> --data-dir <dir> [--cache-dir <dir>]\n");
    return 2;
  }
  if (cacheDir.empty()) cacheDir = dataDir + "/cache";
  H().log = getenv("RNI_WEBHELPER_LOG") != nullptr;

  // A destroyed view's web process must EXIT. The default cache model
  // (WEB_BROWSER = CacheModel::PrimaryWebBrowser) turns on WebKit's
  // WebProcessCache: WebProcessProxy::maybeShutDown parks a closed page's
  // process for 5 min (WebProcessCache.cpp cachedProcessLifetime, non-Cocoa)
  // with its whole heap, RAM/256 MB of them. On the board that held ~300 MB
  // PSS after the streaming tile unmounted.
  // DOCUMENT_BROWSER disables that cache and keeps the back/forward cache at
  // 2 pages. The capacity is fixed when the process pool is BUILT
  // (WebProcessCache ctor -> updateCapacity), so this must run before anything
  // creates the default context. The setter ignores its context argument
  // (the model is process-global), so it does not create one either.
  webkit_web_context_set_cache_model(nullptr, WEBKIT_CACHE_MODEL_DOCUMENT_BROWSER);

  H().sock = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  if (sockPath.size() >= sizeof addr.sun_path) return 3;
  memcpy(addr.sun_path, sockPath.c_str(), sockPath.size() + 1);
  if (connect(H().sock, (sockaddr*)&addr, sizeof addr) != 0) {
    perror("rni-webhelper: connect");
    return 3;
  }

  // Persistent session: cookies in SQLite under data-dir, so streaming sign-in
  // survives navigation AND restarts; kClearData is the sign-out wipe.
  H().session = webkit_network_session_new(dataDir.c_str(), cacheDir.c_str());
  WebKitCookieManager* cm = webkit_network_session_get_cookie_manager(H().session);
  const std::string cookies = dataDir + "/cookies.sqlite";
  webkit_cookie_manager_set_persistent_storage(cm, cookies.c_str(),
                                               WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
  webkit_cookie_manager_set_accept_policy(cm, WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY);
  H().display = wpe_display_headless_new();

  H().loop = g_main_loop_new(nullptr, FALSE);
  g_unix_fd_add(H().sock, (GIOCondition)(G_IO_IN | G_IO_HUP | G_IO_ERR), OnSocket, nullptr);

  const char* cdm = getenv("OCDM_WIDEVINE_CDM");
#if defined(RNI_WEBHELPER_EME)
  const char* eme = "1";
#else
  const char* eme = "0";
#endif
  char ver[32];
  snprintf(ver, sizeof ver, "%u.%u.%u", webkit_get_major_version(), webkit_get_minor_version(),
           webkit_get_micro_version());
  Send(wp::Writer(wp::kReady, 0).num(wp::kVersion).str(ver).str(eme).str(cdm ? cdm : ""));
  printf("rni-webhelper: ready webkit=%s eme=%s cdm=%s data=%s\n", ver, eme, cdm ? cdm : "",
         dataDir.c_str());

  g_main_loop_run(H().loop);
  printf("rni-webhelper: exit views=%zu\n", H().views.size());
  fflush(stdout);
  _Exit(0);  // WebKit teardown can stall headless; the engine already went away
}
