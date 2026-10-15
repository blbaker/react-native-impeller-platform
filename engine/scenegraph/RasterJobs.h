// FP-14: GPU work RECORD queues for RASTER.
//
// Model: Flutter's UI thread never touches the GPU. A picture that must become
// a texture (Picture.toImage, lib/ui/painting/picture.cc) hands back a
// DlDeferredImageGPUImpeller (lib/ui/painting/display_list_deferred_image_gpu_impeller.h)
// whose texture the raster thread produces later; the display list holds the
// image and the rasterizer resolves it before drawing. The interop C API has no
// deferred image, so we build the same split from two GL facts at our pin:
//   * ImpellerTextureCreateWithOpenGLTextureHandleNew only records a handle
//     (ReactorGLES::CreateHandle with an external name makes no GL call) and
//     releasing an ImpellerTexture only marks its handle for collection;
//   * a GL texture NAME (glGenTextures) has no storage until glTexImage2D.
// So RASTER pre-generates names (GlNamePool), RECORD wraps one in an
// ImpellerTexture, draws it into the display list and queues the job that
// fills it (an upload or an offscreen render + halve chain). RasterFrame runs
// the jobs in record order before it draws the list. RECORD makes no GL call.
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

#include "impeller.h"

namespace rni {

// Texture names generated on the raster side, taken by RECORD. Thread-safe.
class GlNamePool {
 public:
  // RECORD. 0 when empty: the caller falls back as if the GPU path failed.
  uint32_t Take();
  // RASTER (GL context current). Tops the pool up to twice the most names one
  // frame has taken, at least kMinFree.
  void Refill();
  uint64_t starved() const { return starved_.load(std::memory_order_relaxed); }
  static constexpr size_t kMinFree = 256;

 private:
  std::mutex mutex_;
  std::vector<uint32_t> free_;
  size_t takenSinceRefill_ = 0;
  size_t peakTaken_ = 0;
  std::atomic<uint64_t> starved_{0};
};

// A job's outcome, shared with the cache entry that depends on it.
enum JobState : int { kJobPending = 0, kJobDone = 1, kJobFailed = 2 };
using JobFlag = std::shared_ptr<std::atomic<int>>;
inline bool JobFailed(const JobFlag& f) { return f && f->load() == kJobFailed; }

class RasterJobs {
 public:
  RasterJobs(ImpellerContext context, std::shared_ptr<GlNamePool> pool);
  ~RasterJobs();  // jobs never run are marked failed; refs released
  RasterJobs(const RasterJobs&) = delete;
  RasterJobs& operator=(const RasterJobs&) = delete;

  // ---- RECORD side: no GL. ----
  // A pool name wrapped as a w x h RGBA8888 texture; null (and *name 0) when
  // the pool is empty or the wrap fails.
  ImpellerTexture WrapNewName(int w, int h, uint32_t* name);
  // Fill `name` from `rgba` (w*h*4 bytes, kept alive by `keep`): glTexImage2D
  // when `allocate`, else glTexSubImage2D. `texture` is retained until the job
  // runs so its name cannot be collected first.
  JobFlag AddUpload(ImpellerTexture texture, uint32_t name, int w, int h,
                    const uint8_t* rgba, std::shared_ptr<const void> keep,
                    bool allocate, bool clampEdges, bool image);
  // Draw `dl` (adopted) into a startW x startH FBO with depth+stencil, halve it
  // through `hops`, and leave the last stage's colour in `finalName` (wrapped
  // by `finalTexture`, retained until the job runs).
  JobFlag AddOffscreen(ImpellerDisplayList dl, int startW, int startH,
                       std::vector<std::pair<int, int>> hops, uint32_t finalName,
                       ImpellerTexture finalTexture);
  size_t size() const;

  // ---- RASTER side: GL context current. ----
  void Run();
  GlNamePool& pool() { return *pool_; }
  // Process totals for the exit summary: uploads, offscreens, failed jobs.
  struct Totals {
    uint64_t uploads, offscreens, failed;
  };
  static Totals totals();

  // Halve chain shared by both supersample paths: each step at most 2x per
  // axis, stopping within 2x of native (the composite does the last 2x).
  static std::vector<std::pair<int, int>> HalveChain(int w, int h, int nativeW,
                                                     int nativeH);

 private:
  struct Job;
  bool RunUpload(Job& job);
  bool RunOffscreen(Job& job);
  ImpellerContext context_;
  std::shared_ptr<GlNamePool> pool_;
  std::vector<Job> jobs_;
  bool ran_ = false;
};

}  // namespace rni
