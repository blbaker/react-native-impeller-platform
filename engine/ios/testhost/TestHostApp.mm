// iOS Phase 1 test host: app + scene delegate and the --test dispatch.
#import "TestHost.h"

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <map>
#include <vector>

namespace {
std::vector<std::string> gArgs;

// An unknown --test name gets an empty controller and a log line, so the
// gate fails by name instead of timing out on a blank screen.
UIViewController* Missing(const std::string& name) {
  TestLog("unknown_test name=%s", name.c_str());
  return [UIViewController new];
}

// Tests compiled into only some builds of the host (the engine test needs the
// full engine library) register themselves from a static initializer.
std::map<std::string, UIViewController* (*)()>& Registry() {
  static std::map<std::string, UIViewController* (*)()> tests;
  return tests;
}
}  // namespace

bool RegisterTest(const char* name, UIViewController* (*make)()) {
  Registry()[name] = make;
  return true;
}

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
  auto it = Registry().find(name);
  if (it != Registry().end()) return it->second();
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
