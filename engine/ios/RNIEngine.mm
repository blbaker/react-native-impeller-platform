// iOS host phase (Task 3.1): see RNIEngine.h. Built with -fobjc-arc.
//
// The sequence is the desktop headless path's (engine/host/main.cpp, the
// EngineSession block) on a CAMetalLayer instead of an offscreen texture, with
// the frame loop driven by DisplayLinkIOS instead of a --frames counter:
//   context + typography (HeadlessSurfaceMetal.mm's order), EngineSession ctor,
//   setRenderContext, Boot, RunScript, wait for JS idle, StartSurface, wait;
//   per vsync: PumpNativeAnimated, RecordFrame, RasterFrame onto the drawable,
//   Present. RECORD and RASTER both run on the main thread here (one thread,
//   like headless); the desktop windowed pipeline's raster thread is later work.
#import "ios/RNIEngine.h"

#include <cstdio>
#include <fstream>
#include <iterator>
#include <memory>
#include <string>

#include "base/ContextFlags.h"
#include "base/GpuAvailability.h"
#include "fabric/ImageStore.h"
#include "host/DisplayLinkIOS.h"
#include "host/FrameItem.h"
#include "host/FrameTimings.h"
#include "host/GpuAvailabilityIOS.h"
#include "host/MetalSurfaceIOS.h"
#include "host/RecordNoGl.h"
#include "runtime/EngineSession.h"
#include "text/TypographyContexts.h"

static_assert(__has_feature(objc_arc), "RNIEngine.mm must be built with -fobjc-arc");

namespace {
constexpr int kMetalMaxTexture2D = 16384;  // same as HeadlessSurfaceMetal.mm
constexpr int kBootIdleMs = 10000;

struct EngineState {
  std::string bundle, sourceUrl, appName;
  rni::MetalSurfaceIOS surface;
  ImpellerContext context = nullptr;
  ImpellerTypographyContext typography = nullptr;
  std::unique_ptr<rni::EngineSession> session;
  std::unique_ptr<rni::DisplayLinkIOS> link;
  int width = 0, height = 0;
  float scale = 1;
  bool destroyed = false;
};
}  // namespace

@implementation RNIEngine {
  std::unique_ptr<EngineState> _s;
  NSUInteger _presented;
  BOOL _firstFrameReported;
}

- (nullable instancetype)initWithBundlePath:(NSString*)bundlePath appName:(NSString*)appName {
  if (!(self = [super init])) return nil;
  std::ifstream in(bundlePath.fileSystemRepresentation, std::ios::binary);
  std::string bundle((std::istreambuf_iterator<char>(in)), {});
  if (bundle.empty()) {
    std::printf("rni-ios: engine bundle_unreadable path=%s\n", bundlePath.UTF8String);
    std::fflush(stdout);
    return nil;
  }
  _s = std::make_unique<EngineState>();
  _s->bundle = std::move(bundle);
  _s->sourceUrl = std::string("file://") + bundlePath.UTF8String;
  _s->appName = appName.UTF8String;
  return self;
}

- (NSUInteger)presentedFrames {
  return _presented;
}

// First attach only: context, typography, EngineSession, JS boot.
- (BOOL)bootWithView:(UIView*)view {
  EngineState& s = *_s;
  rni::image::SetMaxTextureSize(kMetalMaxTexture2D);
  rni::contextflags::ApplyBeforeCreate();
  s.context = s.surface.CreateContext();
  rni::contextflags::Report(s.context);
  if (!s.context) return NO;
  s.typography = ImpellerTypographyContextNew();
  if (!s.typography) return NO;
  rni::typography::Bind(s.typography);
  rni::recordgl::ContextHooks hooks;  // no GL context exists on iOS
  hooks.release = [] { return true; };
  hooks.acquire = [] { return true; };
  hooks.isCurrent = [] { return false; };
  rni::recordgl::SetContextHooks(std::move(hooks));
  rni::gpu::InstallGpuAvailabilityObservers();

  s.session = std::make_unique<rni::EngineSession>(s.typography, rni::GpuBackend::kMetal,
                                                   rni::GpuBackend::kMetal);
  s.session->sceneGraph().setRenderContext(s.context);
  s.session->sceneGraph().printGpuBackend();
  rni::EngineSession::Options options;
  options.colorScheme =
      view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? "dark" : "light";
  s.session->Boot(s.width, s.height, s.scale, options);
  s.session->RunScript(std::move(s.bundle), s.sourceUrl);
  s.bundle.clear();
  const bool evaluated = s.session->WaitForJsIdle(kBootIdleMs);
  s.session->StartSurface(s.appName, s.width, s.height, s.scale);
  const bool started = s.session->WaitForJsIdle(kBootIdleMs);
  std::printf("rni-ios: engine booted app=%s surface=%dx%d scale=%.2f js_idle_after_eval=%d "
              "js_idle_after_start=%d\n",
              s.appName.c_str(), s.width, s.height, s.scale, evaluated, started);
  std::fflush(stdout);
  return YES;
}

- (BOOL)attachToView:(UIView*)view {
  if (!_s || _s->destroyed) return NO;
  EngineState& s = *_s;
  std::string error;
  if (!s.surface.Attach(view, &error)) {
    std::printf("rni-ios: engine attach_failed error=%s\n", error.c_str());
    std::fflush(stdout);
    return NO;
  }
  s.surface.SyncFromView(&s.width, &s.height);
  s.scale = (float)view.layer.contentsScale;
  if (!s.session && ![self bootWithView:view]) {
    std::printf("rni-ios: engine boot_failed (no Metal context or typography)\n");
    std::fflush(stdout);
    return NO;
  }
  __weak RNIEngine* weakSelf = self;
  s.link = std::make_unique<rni::DisplayLinkIOS>([weakSelf](int64_t, int64_t, int64_t) {
    [weakSelf frame];
  });
  return s.link->ok();
}

// Main thread, once per vsync.
- (void)frame {
  EngineState& s = *_s;
  if (!s.session) return;
  int w = 0, h = 0;
  s.surface.SyncFromView(&w, &h);
  if (w > 0 && h > 0 && (w != s.width || h != s.height)) {
    s.width = w;
    s.height = h;
    s.session->ApplyResize(w, h, s.scale);
  }
  rni::gpu::Section section;  // no GPU work while backgrounded (GpuAvailabilityIOS)
  if (!section.available()) {
    rni::gpu::Note(rni::gpu::Counter::kSkippedFrame);
    return;
  }
  s.session->PumpNativeAnimated();
  auto timings = std::make_unique<rni::FrameTimingsRecorder>();
  timings->RecordVsync();
  timings->RecordBuildStart();
  auto item = s.session->RecordFrame(s.scale, s.width, s.height, std::move(timings));
  if (!item || !item->displayList) return;
  const bool drew = rni::RasterFrame(*item, [&s](ImpellerDisplayList dl) {
    return s.surface.Draw(s.context, dl);
  });
  if (!drew) return;
  s.surface.Present();
  rni::gpu::Note(rni::gpu::Counter::kPresent);
  ++_presented;
  if (!_firstFrameReported && item->painted > 1) {
    _firstFrameReported = YES;
    std::printf("rni-ios: engine first_frame presented=%lu painted=%d size=%dx%d\n",
                (unsigned long)_presented, item->painted, item->width, item->height);
    std::fflush(stdout);
    if (self.onFirstFrame) self.onFirstFrame();
  }
}

- (void)detach {
  if (!_s) return;
  _s->link.reset();
  _s->surface.Release();
}

- (void)destroy {
  if (!_s || _s->destroyed) return;
  [self detach];
  rni::gpu::RemoveGpuAvailabilityObservers();
  _s->session.reset();
  if (_s->typography) {
    rni::typography::Unbind(_s->typography);
    ImpellerTypographyContextRelease(_s->typography);
  }
  if (_s->context) ImpellerContextRelease(_s->context);
  _s->typography = nullptr;
  _s->context = nullptr;
  _s->destroyed = true;
}

- (void)dealloc {
  [self destroy];
}

@end
