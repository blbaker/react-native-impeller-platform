// iOS Phase 0 / Task 0.3: raw CAMetalLayer smoke test, no React Native.
//
// One UIViewController whose view is backed by a CAMetalLayer. Every vsync
// (CADisplayLink) it takes the layer's next drawable, wraps it as an Impeller
// surface (ImpellerSurfaceCreateWrappedMetalDrawableNew), draws a display list
// (orange fill + a green rect in the middle third) and presents it. A host-side
// script screenshots the simulator and checks the colors.
//
// Launch argument --mode=nopresent draws the same display list but skips
// ImpellerSurfacePresent: the mutant the screenshot check must reject.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>

#include <cstdio>
#include <cstring>

#include "impeller.h"

static bool gPresent = true;

@interface SmokeMetalView : UIView
@end
@implementation SmokeMetalView
+ (Class)layerClass {
  return [CAMetalLayer class];
}
@end

@interface SmokeViewController : UIViewController
@end

@implementation SmokeViewController {
  ImpellerContext _ctx;
  CADisplayLink* _link;
  int _frames;
}

- (void)loadView {
  self.view = [[SmokeMetalView alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.view.backgroundColor = UIColor.blackColor;
}

- (BOOL)prefersStatusBarHidden {
  return YES;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  CAMetalLayer* layer = (CAMetalLayer*)self.view.layer;
  // ImpellerContextCreateMetalNew uses the system default device; the layer
  // must hand out drawables from the same one (impeller.h, WrappedMetalDrawable).
  layer.device = MTLCreateSystemDefaultDevice();
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer.framebufferOnly = NO;
  layer.contentsScale = UIScreen.mainScreen.nativeScale;
  _ctx = ImpellerContextCreateMetalNew(IMPELLER_VERSION);
  std::printf("smoke: impeller version %u, context %s, device %s, mode %s\n", ImpellerGetVersion(),
              _ctx ? "CREATED" : "NULL", layer.device.name.UTF8String,
              gPresent ? "present" : "nopresent");
  std::fflush(stdout);
  _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
  [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CAMetalLayer* layer = (CAMetalLayer*)self.view.layer;
  CGSize pts = self.view.bounds.size;
  layer.drawableSize = CGSizeMake(pts.width * layer.contentsScale, pts.height * layer.contentsScale);
}

- (void)tick:(CADisplayLink*)link {
  if (!_ctx) return;
  CAMetalLayer* layer = (CAMetalLayer*)self.view.layer;
  id<CAMetalDrawable> drawable = [layer nextDrawable];
  if (!drawable) return;
  ImpellerSurface surface = ImpellerSurfaceCreateWrappedMetalDrawableNew(_ctx, (__bridge void*)drawable);
  if (!surface) return;
  const float w = layer.drawableSize.width, h = layer.drawableSize.height;

  ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
  ImpellerPaint paint = ImpellerPaintNew();
  const ImpellerColor orange = {1.0f, 128.0f / 255.0f, 0.0f, 1.0f, kImpellerColorSpaceSRGB};
  const ImpellerColor green = {0.0f, 192.0f / 255.0f, 128.0f / 255.0f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &orange);
  ImpellerDisplayListBuilderDrawPaint(b, paint);
  ImpellerPaintSetColor(paint, &green);
  const ImpellerRect mid = {w / 3.0f, h / 3.0f, w / 3.0f, h / 3.0f};
  ImpellerDisplayListBuilderDrawRect(b, &mid, paint);
  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);

  const bool drew = dl && ImpellerSurfaceDrawDisplayList(surface, dl);
  const bool presented = gPresent && drew && ImpellerSurfacePresent(surface);
  if (++_frames == 1 || _frames == 120) {
    std::printf("smoke: frame %d drawable=%.0fx%.0f scale=%.1f drew=%d presented=%d\n", _frames, w,
                h, layer.contentsScale, drew, presented);
    std::fflush(stdout);
  }
  ImpellerDisplayListRelease(dl);
  ImpellerPaintRelease(paint);
  ImpellerDisplayListBuilderRelease(b);
  ImpellerSurfaceRelease(surface);
}
@end

@interface SmokeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@end
@implementation SmokeSceneDelegate
- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)options {
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
  self.window.rootViewController = [SmokeViewController new];
  [self.window makeKeyAndVisible];
}
@end

@interface SmokeAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation SmokeAppDelegate
@end

int main(int argc, char* argv[]) {
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--mode=nopresent") == 0) gPresent = false;
  }
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([SmokeAppDelegate class]));
  }
}
