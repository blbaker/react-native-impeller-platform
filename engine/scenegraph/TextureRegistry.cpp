// FP-42: see TextureRegistry.h.
#include "scenegraph/TextureRegistry.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

#include "base/Trace.h"

namespace rni {

namespace {

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

}  // namespace

bool ExternalTextureLog() {
  static const bool on = [] {
    const char* v = std::getenv("RNI_EXT_TEXTURE_LOG");
    return v != nullptr && std::strcmp(v, "1") == 0;
  }();
  return on;
}

TextureRegistry::~TextureRegistry() {
  std::map<int64_t, Entry> left;
  {
    std::lock_guard<std::mutex> lock(mu_);
    left.swap(entries_);
  }
  for (auto& [id, e] : left) e.texture->OnUnregistered();
}

int64_t TextureRegistry::NextId() {
  std::lock_guard<std::mutex> lock(mu_);
  return nextId_++;
}

void TextureRegistry::Register(std::shared_ptr<ExternalTexture> texture) {
  if (!texture) return;
  const int64_t id = texture->id();
  {
    std::lock_guard<std::mutex> lock(mu_);
    Entry& e = entries_[id];
    e = Entry{};
    e.texture = std::move(texture);
    ++registered_;
  }
  std::printf("rn-impeller: ext_texture_register id=%lld t_us=%lld\n", (long long)id,
              (long long)NowUs());
  std::fflush(stdout);
  Notify();
}

bool TextureRegistry::Unregister(int64_t id) {
  std::shared_ptr<ExternalTexture> gone;
  {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = entries_.find(id);
    if (it == entries_.end()) return false;
    gone = std::move(it->second.texture);
    entries_.erase(it);
    ++unregistered_;
  }
  std::printf("rn-impeller: ext_texture_unregister id=%lld t_us=%lld\n", (long long)id,
              (long long)NowUs());
  std::fflush(stdout);
  gone->OnUnregistered();  // Flutter Texture::OnTextureUnregistered
  Notify();                // the next frame paints without it
  return true;
}

void TextureRegistry::MarkFrameAvailable(int64_t id) {
  {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = entries_.find(id);
    if (it == entries_.end()) return;
    it->second.dirty = true;  // embedder MarkNewFrameAvailable: last_image_ = nullptr
    ++it->second.marks;
    ++marks_;
  }
  Notify();  // shell.cc OnPlatformViewMarkTextureFrameAvailable: ScheduleFrame
}

TextureRegistry::Resolved TextureRegistry::Resolve(int64_t id) {
  std::shared_ptr<ExternalTexture> tex;
  uint64_t marks = 0;
  {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = entries_.find(id);
    if (it == entries_.end()) return {};
    ++resolves_;
    if (!it->second.dirty) return {it->second.last, it->second.marks};
    tex = it->second.texture;
    marks = it->second.marks;
  }
  // The producer's own lock is taken outside ours (it may call Mark meanwhile).
  std::shared_ptr<const ExternalFrame> frame = tex->CopyFrame();
  std::lock_guard<std::mutex> lock(mu_);
  auto it = entries_.find(id);
  if (it == entries_.end() || it->second.texture != tex) return {};
  if (frame) it->second.last = frame;
  // A mark that arrived during CopyFrame keeps the entry dirty.
  if (it->second.marks == marks && frame) it->second.dirty = false;
  return {it->second.last, marks};
}

void TextureRegistry::SetFrameListener(std::function<void()> listener) {
  std::lock_guard<std::mutex> lock(listenerMu_);
  listener_ = std::move(listener);
}

void TextureRegistry::Notify() {
  std::lock_guard<std::mutex> lock(listenerMu_);
  if (listener_) listener_();
}

size_t TextureRegistry::size() const {
  std::lock_guard<std::mutex> lock(mu_);
  return entries_.size();
}

void TextureRegistry::PrintSummary() const {
  std::lock_guard<std::mutex> lock(mu_);
  std::printf("rn-impeller: external_textures registered=%llu unregistered=%llu live=%zu marks=%llu "
              "resolves=%llu\n",
              (unsigned long long)registered_, (unsigned long long)unregistered_, entries_.size(),
              (unsigned long long)marks_, (unsigned long long)resolves_);
  std::fflush(stdout);
}

namespace {

class TestPatternTexture final : public ExternalTexture {
 public:
  TestPatternTexture(TextureRegistry* registry, int64_t id, double fps, int w, int h,
                     uint64_t maxFrames)
      : ExternalTexture(id), registry_(registry), fps_(fps), w_(w), h_(h), max_(maxFrames) {}
  ~TestPatternTexture() override { Stop(); }

  void Start() {
    thread_ = std::thread([this] { Run(); });
  }

  std::shared_ptr<const ExternalFrame> CopyFrame() override {
    std::lock_guard<std::mutex> lock(mu_);
    return latest_;
  }

  void OnUnregistered() override { Stop(); }

 private:
  void Stop() {
    {
      std::lock_guard<std::mutex> lock(mu_);
      stop_ = true;
    }
    cv_.notify_all();
    if (thread_.joinable() && thread_.get_id() != std::this_thread::get_id()) thread_.join();
  }

  std::shared_ptr<ExternalFrame> Make(uint64_t k) const {
    auto f = std::make_shared<ExternalFrame>();
    f->seq = k;
    f->width = w_;
    f->height = h_;
    f->rgba.resize((size_t)w_ * h_ * 4);
    const uint8_t r = (uint8_t)((k % 32) * 8), g = (uint8_t)((k / 32 % 32) * 8);
    for (int y = 0; y < h_; ++y) {
      for (int x = 0; x < w_; ++x) {
        uint8_t* p = &f->rgba[((size_t)y * w_ + x) * 4];
        const bool marker = x < w_ / 2 && y < h_ / 2;
        p[0] = marker ? 0 : r;
        p[1] = marker ? 0 : g;
        p[2] = marker ? 255 : 0;
        p[3] = 255;
      }
    }
    return f;
  }

  void Run() {
    trace::SetThreadName("ext-texture");
    const auto period = std::chrono::microseconds((int64_t)(1e6 / (fps_ > 0 ? fps_ : 30)));
    auto next = std::chrono::steady_clock::now();
    for (uint64_t k = 1; max_ == 0 || k <= max_; ++k) {
      std::shared_ptr<ExternalFrame> f = Make(k);
      {
        std::lock_guard<std::mutex> lock(mu_);
        if (stop_) return;
        latest_ = std::move(f);
      }
      if (ExternalTextureLog()) {
        std::printf("rn-impeller: ext_texture_produce id=%lld seq=%llu t_us=%lld\n", (long long)id(),
                    (unsigned long long)k, (long long)NowUs());
        std::fflush(stdout);
      }
      registry_->MarkFrameAvailable(id());
      next += period;
      std::unique_lock<std::mutex> lock(mu_);
      if (cv_.wait_until(lock, next, [this] { return stop_; })) return;
    }
  }

  TextureRegistry* registry_;
  const double fps_;
  const int w_, h_;
  const uint64_t max_;
  std::mutex mu_;
  std::condition_variable cv_;
  bool stop_ = false;
  std::shared_ptr<const ExternalFrame> latest_;
  std::thread thread_;
};

}  // namespace

std::shared_ptr<ExternalTexture> MakeTestPatternTexture(TextureRegistry* registry, int64_t id,
                                                        double fps, int width, int height,
                                                        uint64_t maxFrames) {
  auto t = std::make_shared<TestPatternTexture>(registry, id, fps, width, height, maxFrames);
  t->Start();
  return t;
}

}  // namespace rni
