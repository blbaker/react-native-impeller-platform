// Engine side of the web view (react-native-webview on rn-impeller).
//
// WebKit runs in a separate helper process (rni-webhelper, see
// WebViewProtocol.h for why). This host owns that process: it listens on a
// private AF_UNIX socket, spawns the helper, queues commands until it connects,
// turns FRAME messages into FP-42 external-texture frames (each web view IS an
// ExternalTexture producer, so <ImpellerTextureView textureId> paints it with
// the view's clip/transform/opacity like any video), and hands page events to
// the ImpellerWebView TurboModule.
//
// Helper command: $RNI_WEBHELPER (a shell command line; tools/webhelper-docker.sh
// on WSL runs it in the WPE container) or <dir of rn-impeller>/rni-webhelper.
// It is started with `--socket <path> --data-dir <dir>`; data dir =
// $RNI_WEBVIEW_DATA_DIR or $XDG_DATA_HOME/rn-impeller/webview (cookies persist).
//
// Builds without a backend (non-Linux today) compile WebViewNone.cpp:
// Supported() is false and Create() fails with the reason.
#pragma once

#include <cstdint>
#include <cstdio>
#include <functional>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace rni {

class TextureRegistry;

class WebViewHost {
 public:
  using Headers = std::vector<std::pair<std::string, std::string>>;
  // (viewId, type, json). viewId 0 = host-wide (helper status, dataCleared).
  using EventListener = std::function<void(int64_t, const std::string&, const std::string&)>;

  static WebViewHost& Instance();  // process-wide; never destroyed (exit closes the socket)

  virtual ~WebViewHost() = default;
  virtual bool Supported(std::string* why) = 0;
  // Registers a texture in `registry` and returns its id (= the view id).
  // Never blocks on the helper: commands queue until it connects.
  virtual int64_t Create(std::shared_ptr<TextureRegistry> registry, int width, int height,
                         double scale, const std::string& userAgent, std::string* error) = 0;
  virtual void Load(int64_t id, const std::string& url, const Headers& headers) = 0;
  virtual void Resize(int64_t id, int width, int height, double scale) = 0;
  virtual void Nav(int64_t id, const std::string& action) = 0;  // back forward reload stop
  virtual void Inject(int64_t id, const std::string& js) = 0;
  virtual void UserScript(int64_t id, const std::string& js, bool atStart) = 0;
  virtual bool Destroy(int64_t id) = 0;
  virtual void ClearData() = 0;
  virtual void SetEventListener(EventListener listener) = 0;  // null clears; waits out a call
  virtual std::string StatusJson() = 0;
  // Engine exit (main, after the windowed run): ends the helper AFTER the
  // commands already sent (each view's kDestroy) and reaps it, printing
  // `webview_helper_exit pid=P code=C | signal=S | timeout_ms=B`. No helper = no-op.
  // Budget: $RNI_WEBHELPER_EXIT_MS (default 3000).
  virtual void Shutdown() {}

  // Input (WebViewInput.cpp). Coordinates are CSS px inside the view.
  virtual bool IsWebView(int64_t textureId) = 0;
  virtual void Pointer(int64_t id, const char* kind, int button, double x, double y,
                       uint32_t mods, int clicks) = 0;
  virtual void Touch(int64_t id, const char* kind, double x, double y, uint32_t mods) = 0;
  virtual void Scroll(int64_t id, double x, double y, double dx, double dy, uint32_t mods) = 0;
  virtual void Key(int64_t id, bool down, uint32_t keyval, uint32_t keycode, uint32_t mods) = 0;
  virtual void Focus(int64_t id, bool on) = 0;
  // App-drawn keyboard: `utf8` is committed into the page's focused editable the
  // way an input method commits (kText). Keys go through Key(), like GLFW's.
  virtual void Text(int64_t id, const std::string& utf8) = 0;

  // Keyboard focus: the focused web view (0 = none) and the app keyboard's hold on
  // it (ImpellerWebView.setKeepFocus). Engine-side state, the same on every
  // backend. The window's input handlers (WebViewInput) move focus on their
  // thread; JS sets and clears the hold on its own. Every change happens under
  // focusMu_ and sends Focus() while holding it, so the helper sees focus changes
  // in the order they were decided.
  void SetFocused(int64_t id) {
    std::lock_guard<std::mutex> lock(focusMu_);
    MoveFocusLocked(id);
  }
  int64_t Focused() {
    std::lock_guard<std::mutex> lock(focusMu_);
    return focused_;
  }
  // A press outside every web view blurs the focused one, as a native web view
  // does, unless the app holds it for its own keyboard: those keys are RN views
  // out there, and a blur would drop the editable they type into. Returns the
  // held view's id, 0 when the press blurred it or nothing was focused.
  int64_t PressOutside() {
    std::lock_guard<std::mutex> lock(focusMu_);
    if (focused_ && keep_.count(focused_)) return focused_;
    MoveFocusLocked(0);
    return 0;
  }
  // Clearing the hold on the focused view blurs it (editableFocus focused=false).
  // A tap on an editable that still has focus changes nothing WebKit reports, so
  // without the blur the next tap on that field would never report it again.
  void SetKeepFocus(int64_t id, bool keep) {
    std::lock_guard<std::mutex> lock(focusMu_);
    const bool changed = keep ? keep_.insert(id).second : keep_.erase(id) > 0;
    if (!changed) return;
    const bool blur = !keep && focused_ == id;
    if (blur) MoveFocusLocked(0);
    printf("rn-impeller: webview keep_focus id=%lld on=%d%s\n", (long long)id, keep ? 1 : 0,
           blur ? " blur=1" : "");
    fflush(stdout);
  }

 private:
  void MoveFocusLocked(int64_t id) {
    if (focused_ == id) return;
    if (focused_) Focus(focused_, false);
    focused_ = id;
    if (focused_) Focus(focused_, true);
  }

  std::mutex focusMu_;
  int64_t focused_ = 0;
  std::set<int64_t> keep_;
};

// RNI_WEBVIEW_LOG=1: a `webview_frame` line for the first frames of each view.
bool WebViewLog();

}  // namespace rni
