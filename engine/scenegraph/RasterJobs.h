// FP-14: GPU work RECORD queues for RASTER.
//
// Model: Flutter's UI thread never touches the GPU. A picture that must become
// a texture (Picture.toImage, lib/ui/painting/picture.cc) hands back a
// DlDeferredImageGPUImpeller (lib/ui/painting/display_list_deferred_image_gpu_impeller.h)
// whose texture the raster thread produces later; the display list holds the
// image and the rasterizer resolves it before drawing.
//
// FP-20: the queue is backend-neutral. A backend (scenegraph/GpuBackend.h)
// queues a closure; RasterFrame runs them in record order before it draws the
// list. The GL backend (TextureUploaderGl.cpp, SupersampleBackendGl.cpp) is
// the only one that queues work today: Metal/Vulkan upload through Impeller
// directly and get MSAA from the surface.
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <utility>
#include <vector>

namespace rni {

// A job's outcome, shared with the cache entry that depends on it.
enum JobState : int { kJobPending = 0, kJobDone = 1, kJobFailed = 2 };
using JobFlag = std::shared_ptr<std::atomic<int>>;
inline bool JobFailed(const JobFlag& f) { return f && f->load() == kJobFailed; }

class RasterJobs {
 public:
  enum class Kind { kUpload, kOffscreen };
  // `afterRaster` runs on the raster side after the frame is drawn (the GL
  // backend tops up its texture-name pool there).
  explicit RasterJobs(std::function<void()> afterRaster = nullptr);
  ~RasterJobs();  // jobs never run are marked failed; their captures released
  RasterJobs(const RasterJobs&) = delete;
  RasterJobs& operator=(const RasterJobs&) = delete;

  // RECORD. `run` executes on the raster side with the backend's context
  // current and returns success. Whatever it captures (retained textures, the
  // CPU pixels) is released right after it runs, or with the queue if the
  // frame is dropped unrun.
  JobFlag Add(Kind kind, std::function<bool()> run);
  size_t size() const { return jobs_.size(); }

  // RASTER.
  void Run();
  void AfterRaster();

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
  struct Job {
    Kind kind;
    JobFlag flag;
    std::function<bool()> run;
  };
  std::function<void()> afterRaster_;
  std::vector<Job> jobs_;
  bool ran_ = false;
};

}  // namespace rni
