// The XCUITest for tools/ci-ios-keyboard.sh: brings the software keyboard up
// over a KeyboardAvoidingView and takes it down again, with a screenshot of
// each state. The input sits just above the footer at the bottom of the
// screen; the test finds it from the app's height.
// Environment (the gate writes it into the .xctestrun):
//   RNI_UITEST_APP, RNI_UITEST_ARGS   the test host and its launch arguments
//   RNI_INPUT_H, RNI_FOOTER_H         the fixture's input and footer heights
//   RNI_SHOT_UP, RNI_SHOT_DOWN        screenshot paths (host side)
// Logs `rni-uitest ...` lines.
#import <XCTest/XCTest.h>

@interface RniKeyboardUITests : XCTestCase
@end

@implementation RniKeyboardUITests

static double EnvNum(NSString* key) {
  return [NSProcessInfo.processInfo.environment[key] doubleValue];
}

static void Shot(NSString* path, NSString* what) {
  if (!path.length) return;
  const BOOL wrote = [XCUIScreen.mainScreen.screenshot.PNGRepresentation writeToFile:path atomically:YES];
  NSLog(@"rni-uitest screenshot_%@=%d", what, wrote);
}

- (void)testKeyboardAvoidingView {
  NSDictionary<NSString*, NSString*>* env = NSProcessInfo.processInfo.environment;
  XCUIApplication* app = [[XCUIApplication alloc] initWithBundleIdentifier:env[@"RNI_UITEST_APP"]];
  app.launchArguments = [env[@"RNI_UITEST_ARGS"] componentsSeparatedByString:@" "];
  [app launch];
  XCTAssertTrue([app waitForState:XCUIApplicationStateRunningForeground timeout:30]);
  [NSThread sleepForTimeInterval:6];  // engine boot; no accessibility element to wait on

  const CGSize size = app.frame.size;
  const double inputY = size.height - EnvNum(@"RNI_FOOTER_H") - EnvNum(@"RNI_INPUT_H") / 2;
  NSLog(@"rni-uitest app_size=%.0fx%.0f input_y=%.0f", size.width, size.height, inputY);
  XCUICoordinate* origin = [app coordinateWithNormalizedOffset:CGVectorMake(0, 0)];
  [[origin coordinateWithOffset:CGVectorMake(size.width / 2, inputY)] tap];
  XCUIElement* keyboard = app.keyboards.firstMatch;
  const BOOL up = [keyboard waitForExistenceWithTimeout:10];
  NSLog(@"rni-uitest keyboard_up=%d", up);
  XCTAssertTrue(up, @"the keyboard never came up");
  XCUIElement* intro = app.buttons[@"Continue"];  // "Slide to Type" card, first keyboard only
  if ([intro waitForExistenceWithTimeout:2]) {
    [intro tap];
    NSLog(@"rni-uitest dismissed=slide_to_type_intro");
  }
  [NSThread sleepForTimeInterval:3];  // the keyboard's animation, then KeyboardAvoidingView's
  Shot(env[@"RNI_SHOT_UP"], @"up");

  // A tap on the empty top half focuses nothing, so the keyboard goes.
  [[origin coordinateWithOffset:CGVectorMake(size.width / 2, size.height / 4)] tap];
  const BOOL down = [keyboard waitForNonExistenceWithTimeout:10];
  NSLog(@"rni-uitest keyboard_down=%d", down);
  XCTAssertTrue(down, @"the keyboard never went away");
  [NSThread sleepForTimeInterval:3];
  Shot(env[@"RNI_SHOT_DOWN"], @"down");
}

@end
