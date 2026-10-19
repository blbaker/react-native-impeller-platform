// iOS Phase 4 spike: the XCUITest that drives tools/ci-ios-input.sh with REAL
// UIKit input (taps through the simulator's touch system, keys on the software
// keyboard). Everything it needs comes from the environment the gate writes
// into the .xctestrun:
//   RNI_UITEST_APP      bundle id of the test host
//   RNI_UITEST_ARGS     launch arguments, space separated
//   RNI_TAP_BUTTON_X/Y  the fixture's Pressable centre, points
//   RNI_TAP_INPUT_X/Y   the fixture's TextInput centre, points
//   RNI_UITEST_TYPE     the text to type, key by key (lowercase + spaces)
//   RNI_UITEST_SHOT     where to write a screenshot at the end (host path)
// It logs `rni-uitest ...` lines (NSLog, in xcodebuild's output).
#import <XCTest/XCTest.h>

@interface RniInputUITests : XCTestCase
@end

@implementation RniInputUITests

static double EnvNum(NSString* key) {
  return [NSProcessInfo.processInfo.environment[key] doubleValue];
}

- (void)testTapAndType {
  NSDictionary<NSString*, NSString*>* env = NSProcessInfo.processInfo.environment;
  XCUIApplication* app = [[XCUIApplication alloc] initWithBundleIdentifier:env[@"RNI_UITEST_APP"]];
  app.launchArguments = [env[@"RNI_UITEST_ARGS"] componentsSeparatedByString:@" "];
  [app launch];
  XCTAssertTrue([app waitForState:XCUIApplicationStateRunningForeground timeout:30]);
  // The engine boots in about 2 s; there is no accessibility element to wait
  // on (one Metal view), so wait a fixed time well past it.
  [NSThread sleepForTimeInterval:6];

  XCUICoordinate* origin = [app coordinateWithNormalizedOffset:CGVectorMake(0, 0)];
  [[origin coordinateWithOffset:CGVectorMake(EnvNum(@"RNI_TAP_BUTTON_X"), EnvNum(@"RNI_TAP_BUTTON_Y"))] tap];
  NSLog(@"rni-uitest tapped=button");
  [NSThread sleepForTimeInterval:1];
  [[origin coordinateWithOffset:CGVectorMake(EnvNum(@"RNI_TAP_INPUT_X"), EnvNum(@"RNI_TAP_INPUT_Y"))] tap];
  NSLog(@"rni-uitest tapped=input");

  XCUIElement* keyboard = app.keyboards.firstMatch;
  const BOOL shown = [keyboard waitForExistenceWithTimeout:10];
  NSLog(@"rni-uitest keyboard_exists=%d", shown);
  XCTAssertTrue(shown, @"the software keyboard never appeared");
  if (shown) {
    // A fresh simulator puts the "Slide to Type" tutorial over the keys on the
    // first keyboard (the gate also pre-sets the default that suppresses it).
    // Its card swallows every key tap, so dismiss it if it is there.
    XCUIElement* intro = app.buttons[@"Continue"];
    if ([intro waitForExistenceWithTimeout:2]) {
      [intro tap];
      NSLog(@"rni-uitest dismissed=slide_to_type_intro");
      [NSThread sleepForTimeInterval:1];
    }
    NSString* text = env[@"RNI_UITEST_TYPE"];
    for (NSUInteger i = 0; i < text.length; ++i) {
      NSString* ch = [text substringWithRange:NSMakeRange(i, 1)];
      XCUIElement* key = [ch isEqualToString:@" "] ? keyboard.keys[@"space"] : keyboard.keys[ch];
      XCTAssertTrue(key.exists, @"no key '%@' on the keyboard", ch);
      XCTAssertTrue(key.isHittable, @"key '%@' is covered (not hittable)", ch);
      if (!key.exists || !key.isHittable) break;
      [key tap];
    }
    NSLog(@"rni-uitest typed=%@", text);
  }
  [NSThread sleepForTimeInterval:2];
  NSString* shot = env[@"RNI_UITEST_SHOT"];
  if (shot.length) {
    const BOOL wrote = [XCUIScreen.mainScreen.screenshot.PNGRepresentation writeToFile:shot atomically:YES];
    NSLog(@"rni-uitest screenshot=%d", wrote);
  }
}

@end
