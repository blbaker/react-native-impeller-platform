// WebViewHost on Linux: views are ExternalTexture producers fed by the helper's
// memfd frame slots (see WebViewProtocol.h).
#include <sys/mman.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>

#include "base/MemTrim.h"
#include "scenegraph/FrameRecycler.h"
#include "scenegraph/TextureRegistry.h"
#include "webview/WebHelperLink.h"
#include "webview/WebViewHost.h"

namespace rni {
namespace wp = webproto;

bool WebViewLog() {
  static const bool on = getenv("RNI_WEBVIEW_LOG") != nullptr;
  return on;
}

namespace {

class WebViewTexture final : public ExternalTexture {
 public:
  explicit WebViewTexture(int64_t id) : ExternalTexture(id) {}
  std::shared_ptr<const ExternalFrame> CopyFrame() override {
    std::lock_guard<std::mutex> lock(mu_);
    return frame_;
  }
  void Publish(std::shared_ptr<const ExternalFrame> f) {
    std::lock_guard<std::mutex> lock(mu_);
    frame_ = std::move(f);
  }
  std::function<void()> onUnregistered;
  void OnUnregistered() override {
    if (onUnregistered) onUnregistered();
  }

 private:
  std::mutex mu_;
  std::shared_ptr<const ExternalFrame> frame_;
};

struct ViewEntry {
  std::shared_ptr<WebViewTexture> texture;
  std::weak_ptr<TextureRegistry> registry;
  // The helper's frame memfd as mapped here (IO thread only).
  uint32_t generation = 0;
  const uint8_t* map = nullptr;
  size_t mapBytes = 0;
  uint64_t frames = 0;
  std::shared_ptr<FrameRecycler> buffers = FrameRecycler::Make();  // OnFrame's RGBA copies
};

class LinuxWebViewHost final : public WebViewHost {
 public:
  bool Supported(std::string* why) override {
    std::string cmd;
    return WebHelperLink::Resolve(&cmd, why);
  }

  int64_t Create(std::shared_ptr<TextureRegistry> registry, int w, int h, double scale,
                 const std::string& ua, std::string* error) override {
    if (!EnsureLink(error)) return 0;
    const int64_t id = registry->NextId();
    auto tex = std::make_shared<WebViewTexture>(id);
    tex->onUnregistered = [this, id] { Destroy(id); };
    {
      std::lock_guard<std::mutex> lock(mu_);
      ViewEntry& e = views_[id];
      e.texture = tex;
      e.registry = registry;
    }
    registry->Register(tex);
    link_->Send(wp::Writer(wp::kCreate, (uint32_t)id).num(w).num(h).num(scale).str(ua).bytes());
    printf("rn-impeller: webview_create id=%lld %dx%d scale=%.2f\n", (long long)id, w, h, scale);
    fflush(stdout);
    return id;
  }

  void Load(int64_t id, const std::string& url, const Headers& headers) override {
    Send(wp::Writer(wp::kLoad, (uint32_t)id).str(url).str(wp::JoinHeaders(headers)));
  }
  void Resize(int64_t id, int w, int h, double scale) override {
    Send(wp::Writer(wp::kResize, (uint32_t)id).num(w).num(h).num(scale));
  }
  void Nav(int64_t id, const std::string& action) override {
    Send(wp::Writer(wp::kNav, (uint32_t)id).str(action));
  }
  void Inject(int64_t id, const std::string& js) override {
    Send(wp::Writer(wp::kInject, (uint32_t)id).str(js));
  }
  void UserScript(int64_t id, const std::string& js, bool atStart) override {
    Send(wp::Writer(wp::kUserScript, (uint32_t)id).str(js).str(atStart ? "start" : "end"));
  }
  bool Destroy(int64_t id) override {
    ViewEntry e;
    {
      std::lock_guard<std::mutex> lock(mu_);
      auto it = views_.find(id);
      if (it == views_.end()) return false;
      e = std::move(it->second);
      views_.erase(it);
    }
    if (e.map) munmap(const_cast<uint8_t*>(e.map), e.mapBytes);
    Send(wp::Writer(wp::kDestroy, (uint32_t)id));
    if (auto reg = e.registry.lock()) reg->Unregister(id);
    printf("rn-impeller: webview_destroy id=%lld frames=%llu frame_buffers=%llu\n", (long long)id,
           (unsigned long long)e.frames, (unsigned long long)e.buffers->allocated());
    fflush(stdout);
    memtrim::Request("webview");
    return true;
  }
  void ClearData() override {
    std::string err;
    if (EnsureLink(&err)) link_->Send(wp::Writer(wp::kClearData, 0).bytes());
  }
  void SetEventListener(EventListener l) override {
    std::lock_guard<std::mutex> lock(listenerMu_);
    listener_ = std::move(l);
  }
  std::string StatusJson() override {
    std::lock_guard<std::mutex> lock(mu_);
    return status_;
  }
  void Shutdown() override {
    WebHelperLink* link = nullptr;
    {
      std::lock_guard<std::mutex> lock(linkMu_);
      link = link_.get();
    }
    // NOT under linkMu_: until the helper is reaped the IO thread still answers
    // frames (Send -> linkMu_), and Stop() joins that thread at the end.
    const char* ms = getenv("RNI_WEBHELPER_EXIT_MS");
    if (link) link->Stop(ms && *ms ? atoi(ms) : 3000);
  }

  bool IsWebView(int64_t id) override {
    std::lock_guard<std::mutex> lock(mu_);
    return views_.count(id) != 0;
  }
  void Pointer(int64_t id, const char* kind, int button, double x, double y, uint32_t mods,
               int clicks) override {
    Send(wp::Writer(wp::kPointer, (uint32_t)id).str(kind).num(button).num(x).num(y).num(mods).num(clicks));
  }
  void Touch(int64_t id, const char* kind, double x, double y, uint32_t mods) override {
    Send(wp::Writer(wp::kTouch, (uint32_t)id).str(kind).num(x).num(y).num(mods));
  }
  void Scroll(int64_t id, double x, double y, double dx, double dy, uint32_t mods) override {
    Send(wp::Writer(wp::kScroll, (uint32_t)id).num(x).num(y).num(dx).num(dy).num(mods));
  }
  void Key(int64_t id, bool down, uint32_t keyval, uint32_t keycode, uint32_t mods) override {
    Send(wp::Writer(wp::kKey, (uint32_t)id).str(down ? "down" : "up").num(keyval).num(keycode).num(mods));
  }
  void Focus(int64_t id, bool on) override {
    Send(wp::Writer(wp::kFocus, (uint32_t)id).str(on ? "1" : "0"));
  }
  void Text(int64_t id, const std::string& utf8) override {
    Send(wp::Writer(wp::kText, (uint32_t)id).str(utf8));
  }

 private:
  void Send(const wp::Writer& w) {
    std::lock_guard<std::mutex> lock(linkMu_);
    if (link_ && link_->started()) link_->Send(w.bytes());
  }

  bool EnsureLink(std::string* error) {
    std::lock_guard<std::mutex> lock(linkMu_);
    if (link_ && link_->started() && !link_->down()) return true;
    link_ = std::make_unique<WebHelperLink>();  // a dead helper is replaced on the next create
    if (link_->Start([this](wp::Message& m) { OnMessage(m); },
                     [this](const std::string& why) { OnDown(why); }, error))
      return true;
    printf("rn-impeller: webview_helper_unavailable reason=%s\n", error->c_str());
    fflush(stdout);
    return false;
  }

  void Emit(int64_t id, const std::string& type, const std::string& json) {
    printf("rn-impeller: webview_event id=%lld type=%s json=%s\n", (long long)id, type.c_str(),
           json.c_str());
    fflush(stdout);
    std::lock_guard<std::mutex> lock(listenerMu_);
    if (listener_) listener_(id, type, json);
  }

  void OnDown(const std::string& why) {
    std::vector<int64_t> ids;
    {
      std::lock_guard<std::mutex> lock(mu_);
      for (auto& [id, e] : views_) ids.push_back(id);
    }
    std::string j = "{\"code\":-1,\"domain\":\"rni-webhelper\",\"description\":\"web helper: ";
    for (char c : why) j += (c == '"' || c == '\\') ? ' ' : c;
    j += "\"}";
    for (int64_t id : ids) {
      Emit(id, "error", j);
      Emit(id, "loadEnd", j);
    }
  }

  void OnMessage(wp::Message& m) {
    if (m.type == wp::kReady) {
      {
        std::lock_guard<std::mutex> lock(mu_);
        status_ = "{\"protocol\":" + m.s(0) + ",\"webkit\":\"" + m.s(1) + "\",\"eme\":" +
                  (m.s(2) == "1" ? "true" : "false") + ",\"cdm\":\"" + m.s(3) + "\"}";
      }
      printf("rn-impeller: webview_helper_ready webkit=%s eme=%s cdm=%s\n", m.s(1).c_str(),
             m.s(2).c_str(), m.s(3).c_str());
      fflush(stdout);
      return;
    }
    if (m.type == wp::kEvent) {
      Emit(m.view, m.s(0), m.s(1));
      return;
    }
    if (m.type == wp::kFrame) OnFrame(m);
    if (m.fd >= 0) close(m.fd);
  }

  void OnFrame(wp::Message& m) {
    const uint32_t gen = (uint32_t)m.i(0);
    const int slot = (int)m.i(1), w = (int)m.i(2), h = (int)m.i(3);
    const size_t slotBytes = (size_t)w * h * 4;
    std::shared_ptr<WebViewTexture> tex;
    std::shared_ptr<TextureRegistry> reg;
    uint64_t n = 0;
    {
      std::lock_guard<std::mutex> lock(mu_);
      auto it = views_.find(m.view);
      if (it == views_.end()) return;
      ViewEntry& e = it->second;
      if (m.fd >= 0 && gen != e.generation) {  // the helper reallocated (first frame / resize)
        if (e.map) munmap(const_cast<uint8_t*>(e.map), e.mapBytes);
        e.mapBytes = slotBytes * wp::kSlots;
        void* p = mmap(nullptr, e.mapBytes, PROT_READ, MAP_SHARED, m.fd, 0);
        e.map = p == MAP_FAILED ? nullptr : static_cast<const uint8_t*>(p);
        e.generation = gen;
      }
      if (!e.map || gen != e.generation || slot < 0 || slot >= wp::kSlots ||
          slotBytes * wp::kSlots > e.mapBytes)
        return;
      auto f = e.buffers->Take();
      f->seq = (uint64_t)m.i(4);
      f->width = w;
      f->height = h;
      f->rgba.assign(e.map + slotBytes * slot, e.map + slotBytes * (slot + 1));
      tex = e.texture;
      reg = e.registry.lock();
      n = ++e.frames;
      tex->Publish(std::move(f));
    }
    Send(wp::Writer(wp::kReleaseSlot, m.view).num(gen).num(slot));
    if (reg) reg->MarkFrameAvailable(m.view);
    if (WebViewLog() && (n <= 3 || n % 60 == 0)) {
      printf("rn-impeller: webview_frame id=%u n=%llu seq=%lld %dx%d\n", m.view,
             (unsigned long long)n, m.i(4), w, h);
      fflush(stdout);
    }
  }

  std::mutex linkMu_;
  std::unique_ptr<WebHelperLink> link_;
  std::mutex mu_;
  std::map<int64_t, ViewEntry> views_;
  std::string status_ = "{}";
  std::mutex listenerMu_;
  EventListener listener_;
};

}  // namespace

WebViewHost& WebViewHost::Instance() {
  static auto* host = new LinuxWebViewHost();  // leaked on purpose: no exit-order hazards
  return *host;
}

}  // namespace rni
