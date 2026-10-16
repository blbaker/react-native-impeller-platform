// FP-43: view snapshots (react-native-view-shot's captureRef) the Flutter way.
//
// Model: shell/common/snapshot_controller_impeller.cc. Scene.toImage / a
// RenderRepaintBoundary.toImage records a display list on the UI thread,
// MakeImpellerSnapshot renders it into a fresh texture on the raster thread
// (DoMakeRasterSnapshot: render target clamped to the max texture size,
// deferred with StoreTaskForGPU while the GPU is unavailable), and
// lib/ui/painting/image_encoding_impeller.cc reads it back and encodes it off
// the raster thread before the callback lands on the UI isolate.
//
// Ours: the JS thread queues a request (RNViewShot.captureRef) and wakes a
// frame. RECORD on main records the node's subtree into its own display list
// (SceneGraph::recordSnapshots) and queues a raster job on that frame; the job
// renders + reads back on the raster thread (RenderBackend::snapshot); the
// encoder thread makes the png/jpg, writes the tmpfile or base64, and the
// module resolves the Promise on the JS thread. A job dropped unrun (frame
// discarded, GPU off, context lost) requeues the request for the next frame.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace rni {

struct SnapshotOptions {
  std::string format{"png"};   // png | jpg
  double quality{1.0};         // jpg, [0, 1]
  std::string result{"tmpfile"};  // tmpfile | base64 | data-uri
  double width{0}, height{0};  // output pixels; 0 = the view's size x device scale
  std::string fileName;        // tmpfile name prefix
};

struct SnapshotOutcome {
  uint64_t id{0};
  bool ok{false};
  std::string value;  // file:// uri, base64 or data uri
  std::string error;
};

// Called once, on the encoder thread (or the caller's thread for an
// immediate failure). The module hops it to JS.
using SnapshotDone = std::function<void(SnapshotOutcome)>;

// The calling thread's OS name (js, main, raster, snapshot) for the log lines.
std::string SnapshotThreadLabel();

struct SnapshotRequest {
  uint64_t id{0};
  int tag{0};  // 0 = the whole screen (captureScreen)
  SnapshotOptions options;
  SnapshotDone done;
  int64_t requestedUs{0};
};

class SnapshotController {
 public:
  SnapshotController();
  ~SnapshotController();

  // Any thread (JS). Queues and wakes a frame. Returns the request id.
  uint64_t Request(int tag, SnapshotOptions options, SnapshotDone done);
  // SceneGraph sets this to its frame wake.
  void SetWake(std::function<void()> wake);

  // RECORD (main): every request queued so far, oldest first.
  std::vector<SnapshotRequest> TakePending();
  // RECORD or RASTER: a request whose job never ran goes back to the queue.
  void Requeue(SnapshotRequest r);
  // RECORD: could not be recorded (no such view, no GPU readback).
  void Fail(SnapshotRequest r, const std::string& error);
  // RASTER: the readback (premultiplied RGBA8, row 0 = top) goes to the encoder.
  // `factor` > 1: rendered at factor x the output size (the root supersample's
  // N), box-averaged down on the encoder thread like the halve chain.
  void Rendered(SnapshotRequest r, std::vector<uint8_t> rgba, int w, int h, int factor,
                int64_t renderUs);

  // Deletes a tmpfile this controller wrote (view-shot releaseCapture).
  bool Release(const std::string& uri);
  // `snapshots requested= rendered= encoded= failed= requeued= released=`
  void PrintSummary() const;
  // Where tmpfiles go: $TMPDIR (or /tmp) + /ReactNative.
  static std::string TempDir();

 private:
  struct EncodeJob {
    SnapshotRequest req;
    std::vector<uint8_t> rgba;
    int w{0}, h{0};
    int factor{1};
  };
  void EncoderLoop();
  void Encode(EncodeJob& job);
  void Wake();

  std::mutex mu_;
  std::deque<SnapshotRequest> pending_;
  std::function<void()> wake_;
  std::deque<EncodeJob> encodeQueue_;
  std::condition_variable encodeCv_;
  bool stopping_{false};
  std::thread encoder_;
  std::atomic<uint64_t> nextId_{1};
  std::atomic<uint64_t> requested_{0}, rendered_{0}, encoded_{0}, failed_{0}, requeued_{0},
      released_{0};
};

}  // namespace rni
