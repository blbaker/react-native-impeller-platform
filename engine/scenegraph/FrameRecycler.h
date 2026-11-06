#pragma once

// Reuses the RGBA buffers of a producer's published ExternalFrames (video
// decode thread, web view IO thread). Before, every shown frame was a new
// width*height*4 vector (3.7 MB at 720p, 8.3 MB at 1080p) freed a few frames
// later on another thread, which is what kept raising glibc's thresholds and
// fragmenting its arenas (base/MemTrim.h). A frame's buffer comes back here
// when the last holder (registry, upload job) drops it; once the producer is
// gone, buffers still in flight are simply freed.

#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

#include "scenegraph/TextureRegistry.h"

namespace rni {

class FrameRecycler : public std::enable_shared_from_this<FrameRecycler> {
 public:
  // keep: spare buffers held for reuse. A frame can be held by the producer's
  // latest, the registry's last resolved and an upload job of up to two frames
  // in flight (raster depth 2), so 4 spares cover a steady stream.
  static std::shared_ptr<FrameRecycler> Make(size_t keep = 4) {
    return std::shared_ptr<FrameRecycler>(new FrameRecycler(keep));
  }

  // A frame whose rgba is a recycled buffer (any size: the caller resizes it).
  std::shared_ptr<ExternalFrame> Take() {
    std::vector<uint8_t> buf;
    {
      std::lock_guard<std::mutex> lock(mu_);
      if (free_.empty()) {
        ++allocated_;
      } else {
        buf = std::move(free_.back());
        free_.pop_back();
      }
    }
    auto* f = new ExternalFrame();
    f->rgba = std::move(buf);
    std::weak_ptr<FrameRecycler> home = weak_from_this();
    return std::shared_ptr<ExternalFrame>(f, [home](ExternalFrame* p) {
      if (auto r = home.lock()) r->Give(std::move(p->rgba));
      delete p;
    });
  }

  // Buffers created so far (the rest of the frames reused one).
  uint64_t allocated() {
    std::lock_guard<std::mutex> lock(mu_);
    return allocated_;
  }

 private:
  explicit FrameRecycler(size_t keep) : keep_(keep) {}
  void Give(std::vector<uint8_t>&& b) {
    std::lock_guard<std::mutex> lock(mu_);
    if (free_.size() < keep_) free_.push_back(std::move(b));
  }

  const size_t keep_;
  std::mutex mu_;
  std::vector<std::vector<uint8_t>> free_;
  uint64_t allocated_ = 0;
};

}  // namespace rni
