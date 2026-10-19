// iOS Phase 1 test host: one UIKit app the tools/ci-*-ios*.sh gates launch in
// the simulator with --test=<name>. Each test is a view controller; results are
// `testhost: ...` lines on stdout (simctl launch --stdout) and files in the
// app's Documents dir (simctl get_app_container).
#pragma once

#import <UIKit/UIKit.h>

#include <string>

void TestLog(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
// --name=value from the launch arguments ("" when absent).
std::string TestArg(const char* name);
NSString* TestDocumentsDir();

UIViewController* MakeMetalTest();            // TestHostMetal.mm (Task 1.1)
UIViewController* MakeVsyncTest();            // TestHostVsync.mm (Task 1.2)
UIViewController* MakeGpuAvailabilityTest();  // TestHostLifecycle.mm (Task 1.3)
UIViewController* MakeSettingsTest();         // TestHostSettings.mm (Task 1.4)
UIViewController* MakeClipboardTest();        // TestHostClipboard.mm (Task 1.5)
// For tests only some host builds carry (TestHostEngine.mm):
//   static const bool registered = RegisterTest("engine", MakeEngineTest);
bool RegisterTest(const char* name, UIViewController* (*make)());
