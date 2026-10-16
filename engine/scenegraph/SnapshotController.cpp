// FP-43: see SnapshotController.h.
#include "scenegraph/SnapshotController.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>

#include "base/Trace.h"
#include "scenegraph/ImageEncode.h"

#if defined(__linux__)
#include <pthread.h>
#endif

namespace rni {
namespace {

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

const char kFileScheme[] = "file://";

// factor x factor box average of premultiplied RGBA (the root supersample's
// halve chain ends in the same average; one rounding instead of log2(N)).
void BoxDownsample(std::vector<uint8_t>* rgba, int* w, int* h, int f) {
  const int ow = *w / f, oh = *h / f, iw = *w;
  std::vector<uint8_t> out((size_t)ow * oh * 4);
  const int n = f * f;
  for (int y = 0; y < oh; ++y) {
    for (int x = 0; x < ow; ++x) {
      int sum[4] = {0, 0, 0, 0};
      for (int dy = 0; dy < f; ++dy) {
        const uint8_t* p = rgba->data() + (((size_t)(y * f + dy) * iw) + (size_t)x * f) * 4;
        for (int dx = 0; dx < f; ++dx, p += 4) {
          for (int c = 0; c < 4; ++c) sum[c] += p[c];
        }
      }
      uint8_t* q = out.data() + ((size_t)y * ow + x) * 4;
      for (int c = 0; c < 4; ++c) q[c] = (uint8_t)((sum[c] + n / 2) / n);
    }
  }
  rgba->swap(out);
  *w = ow;
  *h = oh;
}

}  // namespace

std::string SnapshotThreadLabel() {
#if defined(__linux__)
  char name[32] = {0};
  if (pthread_getname_np(pthread_self(), name, sizeof(name)) == 0 && name[0]) return name;
#endif
  return "-";
}

SnapshotController::SnapshotController() { encoder_ = std::thread([this] { EncoderLoop(); }); }

SnapshotController::~SnapshotController() {
  {
    std::lock_guard<std::mutex> lock(mu_);
    stopping_ = true;
  }
  encodeCv_.notify_all();
  if (encoder_.joinable()) encoder_.join();
  // Never-rendered requests fail; their callbacks hop to a JS thread that may
  // already be gone, which the module's invoker tolerates.
  std::deque<SnapshotRequest> left;
  {
    std::lock_guard<std::mutex> lock(mu_);
    left.swap(pending_);
  }
  for (auto& r : left) {
    if (r.done) r.done({r.id, false, "", "the engine shut down before the snapshot was taken"});
  }
}

uint64_t SnapshotController::Request(int tag, SnapshotOptions options, SnapshotDone done) {
  SnapshotRequest r;
  r.id = nextId_.fetch_add(1);
  r.tag = tag;
  r.options = std::move(options);
  r.done = std::move(done);
  r.requestedUs = NowUs();
  std::printf("rn-impeller: snapshot_request id=%llu tag=%d format=%s result=%s thread=%s t_us=%lld\n",
              (unsigned long long)r.id, tag, r.options.format.c_str(), r.options.result.c_str(),
              SnapshotThreadLabel().c_str(), (long long)r.requestedUs);
  std::fflush(stdout);
  const uint64_t id = r.id;
  {
    std::lock_guard<std::mutex> lock(mu_);
    pending_.push_back(std::move(r));
  }
  requested_.fetch_add(1);
  Wake();
  return id;
}

void SnapshotController::SetWake(std::function<void()> wake) {
  std::lock_guard<std::mutex> lock(mu_);
  wake_ = std::move(wake);
}

void SnapshotController::Wake() {
  std::function<void()> wake;
  {
    std::lock_guard<std::mutex> lock(mu_);
    wake = wake_;
  }
  if (wake) wake();
}

std::vector<SnapshotRequest> SnapshotController::TakePending() {
  std::lock_guard<std::mutex> lock(mu_);
  std::vector<SnapshotRequest> out(std::make_move_iterator(pending_.begin()),
                                   std::make_move_iterator(pending_.end()));
  pending_.clear();
  return out;
}

void SnapshotController::Requeue(SnapshotRequest r) {
  requeued_.fetch_add(1);
  {
    std::lock_guard<std::mutex> lock(mu_);
    pending_.push_front(std::move(r));
  }
  Wake();
}

void SnapshotController::Fail(SnapshotRequest r, const std::string& error) {
  failed_.fetch_add(1);
  std::printf("rn-impeller: snapshot_done id=%llu ok=0 error=\"%s\"\n", (unsigned long long)r.id,
              error.c_str());
  std::fflush(stdout);
  if (r.done) r.done({r.id, false, "", error});
}

void SnapshotController::Rendered(SnapshotRequest r, std::vector<uint8_t> rgba, int w, int h,
                                  int factor, int64_t renderUs) {
  rendered_.fetch_add(1);
  std::printf("rn-impeller: snapshot_render id=%llu tag=%d px=%dx%d ss=%d render_us=%lld "
              "thread=%s\n",
              (unsigned long long)r.id, r.tag, w, h, factor, (long long)renderUs,
              SnapshotThreadLabel().c_str());
  std::fflush(stdout);
  {
    std::lock_guard<std::mutex> lock(mu_);
    encodeQueue_.push_back(EncodeJob{std::move(r), std::move(rgba), w, h, factor});
  }
  encodeCv_.notify_one();
}

void SnapshotController::EncoderLoop() {
  trace::SetThreadName("snapshot");
  for (;;) {
    EncodeJob job;
    {
      std::unique_lock<std::mutex> lock(mu_);
      encodeCv_.wait(lock, [this] { return stopping_ || !encodeQueue_.empty(); });
      if (encodeQueue_.empty()) return;  // stopping, nothing left
      job = std::move(encodeQueue_.front());
      encodeQueue_.pop_front();
    }
    Encode(job);
  }
}

std::string SnapshotController::TempDir() {
  const char* t = std::getenv("TMPDIR");
  std::string base = t && *t ? t : "/tmp";
#if defined(_WIN32)
  if (!(t && *t)) {
    const char* w = std::getenv("TEMP");
    base = w && *w ? w : ".";
  }
#endif
  while (base.size() > 1 && (base.back() == '/' || base.back() == '\\')) base.pop_back();
  return base + "/ReactNative";
}

void SnapshotController::Encode(EncodeJob& job) {
  TRACE_EVENT0("snapshot", "SnapshotEncode");
  const int64_t t0 = NowUs();
  if (job.factor > 1) BoxDownsample(&job.rgba, &job.w, &job.h, job.factor);
  const SnapshotOptions& o = job.req.options;
  const bool jpg = o.format == "jpg";
  std::vector<uint8_t> bytes;
  const bool encoded = jpg ? EncodeJpeg(job.rgba, job.w, job.h, o.quality, &bytes)
                           : EncodePng(job.rgba, job.w, job.h, &bytes);
  if (!encoded) {
    Fail(std::move(job.req), std::string("could not encode the snapshot as ") + o.format);
    return;
  }
  SnapshotOutcome out;
  out.id = job.req.id;
  out.ok = true;
  if (o.result == "tmpfile") {
    std::error_code ec;
    const std::string dir = TempDir();
    std::filesystem::create_directories(dir, ec);
    const std::string prefix = o.fileName.empty() ? "ReactNative-snapshot-image" : o.fileName;
    const std::string path = dir + "/" + prefix + "-" + std::to_string(NowUs()) + "-" +
                             std::to_string(job.req.id) + (jpg ? ".jpg" : ".png");
    std::ofstream f(path, std::ios::binary);
    f.write(reinterpret_cast<const char*>(bytes.data()), (std::streamsize)bytes.size());
    f.close();
    if (!f) {
      Fail(std::move(job.req), "could not write " + path);
      return;
    }
    out.value = kFileScheme + path;
  } else {
    const std::string b64 = Base64(bytes);
    out.value = o.result == "data-uri"
                    ? std::string("data:image/") + (jpg ? "jpeg" : "png") + ";base64," + b64
                    : b64;
  }
  encoded_.fetch_add(1);
  const int64_t now = NowUs();
  std::printf("rn-impeller: snapshot_done id=%llu ok=1 format=%s result=%s px=%dx%d bytes=%zu "
              "encode_us=%lld total_us=%lld thread=%s\n",
              (unsigned long long)job.req.id, o.format.c_str(), o.result.c_str(), job.w, job.h,
              bytes.size(), (long long)(now - t0), (long long)(now - job.req.requestedUs),
              SnapshotThreadLabel().c_str());
  std::fflush(stdout);
  if (job.req.done) job.req.done(std::move(out));
}

bool SnapshotController::Release(const std::string& uri) {
  std::string path = uri;
  if (path.rfind(kFileScheme, 0) == 0) path = path.substr(sizeof(kFileScheme) - 1);
  const std::string dir = TempDir() + "/";
  // Only files this engine wrote: view-shot's releaseCapture is a tmpfile cleanup.
  if (path.rfind(dir, 0) != 0 || path.find("..") != std::string::npos) return false;
  std::error_code ec;
  const bool removed = std::filesystem::remove(path, ec);
  if (removed) released_.fetch_add(1);
  return removed;
}

void SnapshotController::PrintSummary() const {
  std::printf("rn-impeller: snapshots requested=%llu rendered=%llu encoded=%llu failed=%llu "
              "requeued=%llu released=%llu\n",
              (unsigned long long)requested_.load(), (unsigned long long)rendered_.load(),
              (unsigned long long)encoded_.load(), (unsigned long long)failed_.load(),
              (unsigned long long)requeued_.load(), (unsigned long long)released_.load());
  std::fflush(stdout);
}

}  // namespace rni
