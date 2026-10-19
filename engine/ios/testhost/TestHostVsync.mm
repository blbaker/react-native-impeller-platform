// iOS Phase 1 / Task 1.2 test: DisplayLinkIOS paces presents.
// DisplayLinkIOS's sink (main thread) hands every vsync to a serial raster
// queue that draws a moving bar through MetalSurfaceIOS and presents with an
// onDisplayed callback. After 30 warm-up frames it collects 121 samples of
// three clocks: displayed times (MTLDrawable presentedTime, device only), the
// time each Present() call returned (steady clock, raster queue) and the
// sink's own link timestamps, then prints one `vsync ...` line with the
// interval statistics of each.
#import "TestHost.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <mutex>
#include <vector>

#include "host/DisplayLinkIOS.h"
#include "host/MetalSurfaceIOS.h"

namespace {
constexpr int kWarmup = 30;
constexpr size_t kSamples = 121;  // 120 intervals

struct Stats {
  double mean = 0, stddev = 0;
};

Stats IntervalStats(const std::vector<int64_t>& t) {
  Stats s;
  if (t.size() < 2) return s;
  std::vector<double> d;
  for (size_t i = 1; i < t.size(); ++i) d.push_back((double)(t[i] - t[i - 1]));
  for (double v : d) s.mean += v;
  s.mean /= d.size();
  for (double v : d) s.stddev += (v - s.mean) * (v - s.mean);
  s.stddev = std::sqrt(s.stddev / d.size());
  return s;
}
}  // namespace

@interface VsyncTestController : UIViewController
@end

@implementation VsyncTestController {
  rni::MetalSurfaceIOS _surface;
  std::unique_ptr<rni::DisplayLinkIOS> _link;
  ImpellerContext _ctx;
  dispatch_queue_t _raster;
  std::mutex _mu;
  std::vector<int64_t> _presented, _calls, _linkTimes;
  int64_t _lastPeriodUs;
  int _zeroPresented;
  std::atomic<int> _frames, _callbacks, _busySkips;
  std::atomic<bool> _busy, _done;
  int _w, _h;
}

- (void)loadView {
  self.view = [[RNIMetalLayerView alloc] initWithFrame:UIScreen.mainScreen.bounds];
}

- (BOOL)prefersStatusBarHidden {
  return YES;
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (_ctx) return;
  std::string err;
  if (!_surface.Attach(self.view, &err)) {
    TestLog("vsync attach_failed error=%s", err.c_str());
    return;
  }
  _surface.SyncFromView(&_w, &_h);
  _raster = dispatch_queue_create("rni.testhost.raster", DISPATCH_QUEUE_SERIAL);
  dispatch_sync(_raster, ^{
    self->_ctx = self->_surface.CreateContext();
  });
  __weak VsyncTestController* weakSelf = self;
  _link = std::make_unique<rni::DisplayLinkIOS>([weakSelf](int64_t nowUs, int64_t targetUs, int64_t periodUs) {
    [weakSelf vsyncNow:nowUs target:targetUs period:periodUs];
  });
  TestLog("vsync link_ok=%d nominal_period_us=%lld context=%s", _link->ok(),
          (long long)_link->nominalPeriodUs(), _ctx ? "created" : "NULL");
}

// Main thread (the link's run loop). Every callback's timestamp is recorded
// BEFORE the one-frame-in-flight check: the link statistics measure
// DisplayLinkIOS's delivery, not this host's raster backpressure (measured: one
// busy skip recorded as a 33 ms link interval put the stddev at 9.09%).
- (void)vsyncNow:(int64_t)nowUs target:(int64_t)targetUs period:(int64_t)periodUs {
  if (_done.load() || !_ctx) return;
  const int callback = ++_callbacks;
  if (callback > kWarmup) {
    std::lock_guard<std::mutex> lock(_mu);
    if (_linkTimes.size() < kSamples) _linkTimes.push_back(nowUs);
    _lastPeriodUs = periodUs;
  }
  if (_busy.exchange(true)) {
    ++_busySkips;
    return;
  }
  const int frame = ++_frames;
  if (frame % 60 == 0) TestLog("vsync_progress frames=%d", frame);
  const int w = _w, h = _h;
  dispatch_async(_raster, ^{
    [self drawFrame:frame width:w height:h];
    self->_busy.store(false);
  });
}

// Raster queue.
- (void)drawFrame:(int)frame width:(int)w height:(int)h {
  _surface.SetDrawableSize(w, h);
  ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
  ImpellerPaint paint = ImpellerPaintNew();
  const ImpellerColor bg = {0.1f, 0.1f, 0.1f, 1, kImpellerColorSpaceSRGB};
  const ImpellerColor bar = {1, 0.5f, 0, 1, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &bg);
  ImpellerDisplayListBuilderDrawPaint(b, paint);
  ImpellerPaintSetColor(paint, &bar);
  const ImpellerRect r = {(float)((frame * 8) % std::max(1, w - 40)), 0, 40, (float)h};
  ImpellerDisplayListBuilderDrawRect(b, &r, paint);
  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);
  if (_surface.Draw(_ctx, dl)) {
    const bool sample = frame > kWarmup;
    __weak VsyncTestController* weakSelf = self;
    _surface.Present([weakSelf, sample](int64_t presentedUs) {
      if (sample) [weakSelf displayed:presentedUs];
    });
    if (sample) {
      const int64_t now = std::chrono::duration_cast<std::chrono::microseconds>(
                              std::chrono::steady_clock::now().time_since_epoch())
                              .count();
      std::lock_guard<std::mutex> lock(_mu);
      if (_calls.size() < kSamples) _calls.push_back(now);
    }
  }
  ImpellerDisplayListRelease(dl);
  ImpellerPaintRelease(paint);
  ImpellerDisplayListBuilderRelease(b);
}

// Metal's thread. presentedTime can be 0 (never displayed, or a simulator
// that does not report it): those are counted, and once kSamples of them pile
// up the line is printed with the link statistics alone (n=0).
- (void)displayed:(int64_t)presentedUs {
  std::lock_guard<std::mutex> lock(_mu);
  if (presentedUs <= 0) {
    ++_zeroPresented;
  } else if (_presented.size() < kSamples) {
    _presented.push_back(presentedUs);
  }
  const bool presentsDone = _presented.size() >= kSamples || _zeroPresented >= (int)kSamples;
  if (!presentsDone || _calls.size() < kSamples || _linkTimes.size() < kSamples ||
      _done.exchange(true)) {
    return;
  }
  std::vector<int64_t> p = _presented;
  std::sort(p.begin(), p.end());  // handlers may run out of order
  const Stats ps = IntervalStats(p), cs = IntervalStats(_calls), ls = IntervalStats(_linkTimes);
  TestLog("vsync n=%zu present_mean_us=%.0f present_stddev_us=%.0f call_n=%zu call_mean_us=%.0f "
          "call_stddev_us=%.0f link_mean_us=%.0f link_stddev_us=%.0f period_us=%lld nominal_us=%lld "
          "presented_zero=%d presents=%d busy_skips=%d",
          p.empty() ? 0 : p.size() - 1, ps.mean, ps.stddev, _calls.size() - 1, cs.mean, cs.stddev,
          ls.mean, ls.stddev, (long long)_lastPeriodUs,
          (long long)(_link ? _link->nominalPeriodUs() : 0), _zeroPresented, _surface.presents(),
          _busySkips.load());
}
@end

UIViewController* MakeVsyncTest() { return [VsyncTestController new]; }
