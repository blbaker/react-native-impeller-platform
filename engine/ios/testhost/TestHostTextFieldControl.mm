// iOS Phase 4 spike CONTROL: a plain, visible UITextField where the input
// fixture's TextInput is (fixtures/ios-input/geometry.js), so tools/ci-ios-input.sh
// can tell "our proxy drops the keys" from "this simulator delivers no key text
// to anything". Logs `[js] ios-input ...` lines in the fixture's own format.
#import "TestHost.h"

#include <cstdio>

@interface TextFieldControlController : UIViewController <UITextFieldDelegate>
@end

@implementation TextFieldControlController {
  UITextField* _field;
  UIView* _button;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.whiteColor;
  _button = [[UIView alloc] initWithFrame:CGRectMake(40, 180, 160, 80)];
  _button.backgroundColor = UIColor.redColor;
  [_button addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(pressed)]];
  [self.view addSubview:_button];
  _field = [[UITextField alloc] initWithFrame:CGRectMake(40, 300, 300, 50)];
  _field.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1];
  _field.autocorrectionType = UITextAutocorrectionTypeNo;
  _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  _field.spellCheckingType = UITextSpellCheckingTypeNo;
  _field.delegate = self;
  [_field addTarget:self action:@selector(changed) forControlEvents:UIControlEventEditingChanged];
  [self.view addSubview:_field];
  TestLog("engine uikit_points=%.0fx%.0f uikit_scale=%.2f", UIScreen.mainScreen.bounds.size.width,
          UIScreen.mainScreen.bounds.size.height, UIScreen.mainScreen.nativeScale);
}

- (void)pressed {
  _button.backgroundColor = [UIColor colorWithRed:0 green:170 / 255.0 blue:0 alpha:1];
  std::printf("[js] ios-input pressed=1\n");
  std::fflush(stdout);
}

- (void)textFieldDidBeginEditing:(UITextField*)field {
  std::printf("[js] ios-input focus=1\n");
  std::fflush(stdout);
}

- (void)changed {
  std::printf("[js] ios-input value=\"%s\"\n", _field.text.UTF8String);
  std::fflush(stdout);
}
@end

static UIViewController* MakeControl() { return [TextFieldControlController new]; }
[[maybe_unused]] static const bool gRegistered = RegisterTest("textfield", MakeControl);
