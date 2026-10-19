// iOS Phase 1 test host: app + scene delegate and the --test dispatch.
#import "TestHost.h"

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {
std::vector<std::string> gArgs;

// An unknown --test name gets an empty controller and a log line, so the
// gate fails by name instead of timing out on a blank screen.
UIViewController* Missing(const std::string& name) {
  TestLog("unknown_test name=%s", name.c_str());
  return [UIViewController new];
}
}  // namespace

void TestLog(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  std::printf("testhost: ");
  std::vprintf(fmt, ap);
  std::printf("\n");
  std::fflush(stdout);
  va_end(ap);
}

std::string TestArg(const char* name) {
  const std::string prefix = std::string("--") + name + "=";
  for (const std::string& a : gArgs) {
    if (a.rfind(prefix, 0) == 0) return a.substr(prefix.size());
  }
  return "";
}

NSString* TestDocumentsDir() {
  return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static UIViewController* MakeTest(const std::string& name) {
  if (name == "metal") return MakeMetalTest();
  if (name == "vsync") return MakeVsyncTest();
  if (name == "gpu") return MakeGpuAvailabilityTest();
  if (name == "settings") return MakeSettingsTest();
  if (name == "clipboard") return MakeClipboardTest();
  return Missing(name);
}

@interface TestHostSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@end
@implementation TestHostSceneDelegate
- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)options {
  const std::string test = TestArg("test");
  TestLog("start test=%s pid=%d", test.c_str(), getpid());
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
  self.window.rootViewController = MakeTest(test);
  [self.window makeKeyAndVisible];
}
@end

@interface TestHostAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation TestHostAppDelegate
@end

int main(int argc, char* argv[]) {
  for (int i = 1; i < argc; ++i) gArgs.emplace_back(argv[i]);
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([TestHostAppDelegate class]));
  }
}
