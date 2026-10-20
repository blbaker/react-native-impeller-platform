// The XCUITest for tools/ci-ios-text-input.sh: real keyboard input that edits
// by RANGE, not key by key. In the first field it types "teh " on the English
// keyboard (autocorrect replaces it), in the second it switches to the
// Japanese romaji keyboard, types "nihonn" (marked text) and confirms it.
// Environment (the gate writes it into the .xctestrun):
//   RNI_UITEST_APP, RNI_UITEST_ARGS   the test host and its launch arguments
//   RNI_TAP_{AUTO,OFF,JA}_X/Y  field centres, points
//   RNI_TYPE_{AUTO,OFF,JA}     what to type in each (lowercase, spaces)
//   RNI_UITEST_SHOT                   screenshot path (host side)
// Logs `rni-uitest ...` lines.
#import <XCTest/XCTest.h>

@interface RniTextInputUITests : XCTestCase
@end

@implementation RniTextInputUITests

static double EnvNum(NSString* key) {
  return [NSProcessInfo.processInfo.environment[key] doubleValue];
}

// Taps each character's key; " " is the space key. False if a key is missing.
static BOOL TypeKeys(XCUIElement* keyboard, NSString* text) {
  for (NSUInteger i = 0; i < text.length; ++i) {
    NSString* ch = [text substringWithRange:NSMakeRange(i, 1)];
    XCUIElement* key = [ch isEqualToString:@" "] ? keyboard.keys[@"space"] : keyboard.keys[ch];
    if (!key.exists) {
      NSLog(@"rni-uitest missing_key=%@", ch);
      return NO;
    }
    [key tap];
  }
  return YES;
}

static NSString* KeyLabels(XCUIElement* keyboard) {
  NSMutableArray* labels = [NSMutableArray new];
  for (XCUIElement* k in [keyboard.keys allElementsBoundByIndex]) [labels addObject:k.label];
  for (XCUIElement* b in [keyboard.buttons allElementsBoundByIndex]) {
    [labels addObject:[@"btn:" stringByAppendingString:b.label]];
  }
  return [labels componentsJoinedByString:@"|"];
}

- (void)testAutocorrectAndJapanese {
  NSDictionary<NSString*, NSString*>* env = NSProcessInfo.processInfo.environment;
  XCUIApplication* app = [[XCUIApplication alloc] initWithBundleIdentifier:env[@"RNI_UITEST_APP"]];
  app.launchArguments = [env[@"RNI_UITEST_ARGS"] componentsSeparatedByString:@" "];
  [app launch];
  XCTAssertTrue([app waitForState:XCUIApplicationStateRunningForeground timeout:30]);
  [NSThread sleepForTimeInterval:6];  // engine boot; no accessibility element to wait on
  XCUICoordinate* origin = [app coordinateWithNormalizedOffset:CGVectorMake(0, 0)];

  // 1. Autocorrect, English keyboard.
  [[origin coordinateWithOffset:CGVectorMake(EnvNum(@"RNI_TAP_AUTO_X"), EnvNum(@"RNI_TAP_AUTO_Y"))] tap];
  XCUIElement* keyboard = app.keyboards.firstMatch;
  XCTAssertTrue([keyboard waitForExistenceWithTimeout:10], @"no keyboard for the first field");
  XCUIElement* intro = app.buttons[@"Continue"];  // the "Slide to Type" card, first keyboard only
  if ([intro waitForExistenceWithTimeout:2]) {
    [intro tap];
    NSLog(@"rni-uitest dismissed=slide_to_type_intro");
    [NSThread sleepForTimeInterval:1];
  }
  NSLog(@"rni-uitest keys_en=%@", KeyLabels(keyboard));
  XCTAssertTrue(TypeKeys(keyboard, env[@"RNI_TYPE_AUTO"]));
  NSLog(@"rni-uitest typed_auto=%@", env[@"RNI_TYPE_AUTO"]);
  [NSThread sleepForTimeInterval:1.5];

  // 2. The same keys in the autoCorrect={false} field: nothing may change.
  [[origin coordinateWithOffset:CGVectorMake(EnvNum(@"RNI_TAP_OFF_X"), EnvNum(@"RNI_TAP_OFF_Y"))] tap];
  [NSThread sleepForTimeInterval:1];
  XCTAssertTrue(TypeKeys(keyboard, env[@"RNI_TYPE_OFF"]));
  NSLog(@"rni-uitest typed_off=%@", env[@"RNI_TYPE_OFF"]);
  [NSThread sleepForTimeInterval:1.5];

  // 3. Japanese romaji composition in the last field.
  [[origin coordinateWithOffset:CGVectorMake(EnvNum(@"RNI_TAP_JA_X"), EnvNum(@"RNI_TAP_JA_Y"))] tap];
  [NSThread sleepForTimeInterval:1];
  // On a notch iPhone the globe key sits in the strip under the keyboard,
  // outside app.keyboards: search the whole app.
  XCUIElement* next = app.buttons[@"Next keyboard"];
  if (!next.exists) next = keyboard.buttons[@"Next keyboard"];
  if (!next.exists) next = keyboard.keys[@"Next keyboard"];
  NSLog(@"rni-uitest next_keyboard_exists=%d", next.exists);
  if (!next.exists) {
    NSMutableArray* labels = [NSMutableArray new];
    for (XCUIElement* b in [app.buttons allElementsBoundByIndex]) [labels addObject:b.label];
    NSLog(@"rni-uitest app_buttons=%@", [labels componentsJoinedByString:@"|"]);
  }
  XCTAssertTrue(next.exists, @"no Next keyboard key: is a second keyboard installed?");
  if (next.exists) [next tap];
  [NSThread sleepForTimeInterval:1.5];
  NSLog(@"rni-uitest keys_ja=%@", KeyLabels(keyboard));
  XCTAssertTrue(TypeKeys(keyboard, env[@"RNI_TYPE_JA"]));
  NSLog(@"rni-uitest typed_ja=%@", env[@"RNI_TYPE_JA"]);
  [NSThread sleepForTimeInterval:1];
  NSLog(@"rni-uitest keys_ja_composing=%@", KeyLabels(keyboard));
  // The return key confirms a composition (it does not submit while text is
  // marked). Its identifier is "Return"; its label on the Japanese keyboard
  // is 改行.
  XCUIElement* confirm = keyboard.buttons[@"Return"];
  NSLog(@"rni-uitest confirm_exists=%d label=%@", confirm.exists, confirm.exists ? confirm.label : @"");
  XCTAssertTrue(confirm.exists, @"no confirm key");
  if (confirm.exists) [confirm tap];
  [NSThread sleepForTimeInterval:2];

  NSString* shot = env[@"RNI_UITEST_SHOT"];
  if (shot.length) {
    const BOOL wrote = [XCUIScreen.mainScreen.screenshot.PNGRepresentation writeToFile:shot atomically:YES];
    NSLog(@"rni-uitest screenshot=%d", wrote);
  }
}

@end
