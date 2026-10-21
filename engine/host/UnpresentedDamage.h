// The idle-skip loop's guarantee that scene damage reaches the screen.
//
// Under --idle-skip a frame paints only when one was requested, and the
// request is consumed at BeginFrame. A frame can then still fail to reach the
// screen: Metal's nextDrawable returns nil (it waits up to 1 s and gives up),
// a draw fails, the raster thread discards a frame recorded at a stale size.
// Nothing asked for another frame after that, so the window kept the previous
// frame until an unrelated request (a resize) came along. Mac report against
// 0.6.0: Jim's "Open ticket" was committed (the cursor hit-tested the new
// screen) but the old screen stayed up at 0% CPU until the window was resized.
//
// The loop now compares two revisions before it parks: the scene graph's
// damage revision (SceneGraph::version, bumped by every commit and every other
// damage source) and the newest revision a frame actually presented
// (WindowRasterizer::presentedRevision). Behind, with no frame in flight, means
// a frame was lost, so it asks for another one. Repeated failures back off
// (0, 0, 25, 50 ... 1000 ms) so a draw that keeps failing cannot spin a core.
// Model: Flutter's Rasterizer resubmits a frame whose draw returned
// kRetry/kResubmit (shell/common/rasterizer.cc ShouldResubmitFrame).
//
// The backoff counts failures IN A ROW, so any present ends the run. It is not
// enough to reset only when a check finds the screen caught up: after a
// present the loop parks for the whole idle budget (a present does not wake
// it), and a commit landing inside that park means the next check already
// sees new damage. The count then carried into the next commit's losses, and
// a single fresh loss waited 400-800 ms (PR #35 darwin run 39537571277:
// retry=7..10 on swaps 3-4, since_lost_ms=730). Gate:
// tools/ci-unpresented-damage.sh.
#pragma once

#include <algorithm>
#include <cstdint>

namespace rni {

class UnpresentedDamage {
 public:
  struct Decision {
    bool request = false;  // ask the scheduler for a frame now
    int waitMs = -1;       // park no longer than this (-1 = no limit from here)
    int retry = 0;         // 1-based attempt number when request is true
  };

  // Main thread, at the idle check. inFlight: frames submitted and not yet
  // retired (their outcome is still unknown, so nothing to decide yet).
  Decision Check(uint64_t sceneRevision, uint64_t presentedRevision, bool inFlight,
                 int64_t nowUs) {
    Decision d;
    if (presentedRevision != lastPresented_) {
      // A frame reached the screen since the last check: the failure run is
      // over even if newer damage is already waiting. Clear the pending
      // deadline too, or a new loss waits out the old run's backoff.
      lastPresented_ = presentedRevision;
      consecutive_ = 0;
      retryAtUs_ = 0;
    }
    if (presentedRevision >= sceneRevision) {
      consecutive_ = 0;  // caught up: the next loss starts the schedule again
      retryAtUs_ = 0;
      return d;
    }
    if (inFlight) return d;  // its retire wakes the loop
    if (nowUs < retryAtUs_) {
      d.waitMs = (int)std::max<int64_t>(1, (retryAtUs_ - nowUs + 999) / 1000);
      return d;
    }
    ++consecutive_;
    ++requests_;
    retryAtUs_ = nowUs + (int64_t)BackoffMs(consecutive_) * 1000;
    d.request = true;
    d.retry = consecutive_;
    return d;
  }

  // Delay before attempt `n + 1` after attempt n: the first two retries are
  // immediate (a one-off nil drawable), then 25 ms doubling to 1 s.
  static int BackoffMs(int n) {
    if (n <= 2) return 0;
    const int shift = std::min(n - 3, 6);
    return std::min(1000, 25 << shift);
  }

  uint64_t requests() const { return requests_; }

 private:
  int consecutive_ = 0;
  int64_t retryAtUs_ = 0;
  uint64_t lastPresented_ = 0;
  uint64_t requests_ = 0;
};

}  // namespace rni
