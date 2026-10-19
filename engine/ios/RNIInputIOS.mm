// iOS Phase 4 spike: see RNIInputIOS.h. Built with -fobjc-arc.
#import "ios/RNIInputIOS.h"

#import <UIKit/UIGestureRecognizerSubclass.h>

#include <cstdio>

#include "fabric/FabricHost.h"

static_assert(__has_feature(objc_arc), "RNIInputIOS.mm must be built with -fobjc-arc");

using rni::FabricHost;

// ---------------------------------------------------------------------------
// Keyboard: the first responder the system keyboard types into.
@interface RNIKeyboardProxy : UIView <UIKeyInput>
@property(nonatomic, assign) FabricHost* fabric;
@property(nonatomic) UITextAutocorrectionType autocorrectionType;
@property(nonatomic) UITextAutocapitalizationType autocapitalizationType;
@property(nonatomic) UITextSpellCheckingType spellCheckingType;
@property(nonatomic) UITextSmartQuotesType smartQuotesType;
@property(nonatomic) UITextSmartDashesType smartDashesType;
@property(nonatomic) UITextSmartInsertDeleteType smartInsertDeleteType;
@end

@implementation RNIKeyboardProxy
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.autocorrectionType = UITextAutocorrectionTypeNo;
    self.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.spellCheckingType = UITextSpellCheckingTypeNo;
    self.smartQuotesType = UITextSmartQuotesTypeNo;
    self.smartDashesType = UITextSmartDashesTypeNo;
    self.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    self.userInteractionEnabled = NO;  // never the target of a touch
    self.hidden = YES;                 // draws nothing; first responder status is all it needs
  }
  return self;
}
- (BOOL)canBecomeFirstResponder {
  return YES;
}
- (BOOL)becomeFirstResponder {
  const BOOL ok = [super becomeFirstResponder];
  std::printf("rni-ios: keyboard first_responder=%d\n", ok);
  std::fflush(stdout);
  return ok;
}
- (BOOL)resignFirstResponder {
  const BOOL ok = [super resignFirstResponder];
  std::printf("rni-ios: keyboard resigned=%d\n", ok);
  std::fflush(stdout);
  return ok;
}
- (BOOL)hasText {
  return YES;  // so deleteBackward always arrives; the engine's buffer decides
}
- (void)insertText:(NSString*)text {
  if (!_fabric) return;
  NSData* utf32 = [text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
  const uint32_t* cp = static_cast<const uint32_t*>(utf32.bytes);
  const size_t n = utf32.length / 4;
  int tag = 0;
  for (size_t i = 0; i < n; ++i) {
    tag = cp[i] == '\n' ? _fabric->dispatchKey(FabricHost::KeyAction::Submit, 0)
                        : _fabric->dispatchKey(FabricHost::KeyAction::InsertChar, cp[i]);
  }
  std::printf("rni-ios: key insert scalars=%zu tag=%d\n", n, tag);
  std::fflush(stdout);
}
- (void)deleteBackward {
  if (!_fabric) return;
  const int tag = _fabric->dispatchKey(FabricHost::KeyAction::Backspace, 0);
  std::printf("rni-ios: key backspace tag=%d\n", tag);
  std::fflush(stdout);
}
@end

// ---------------------------------------------------------------------------
// Touch: forwards the first touch without cancelling or delaying UIKit's.
@interface RNITouchForwarder : UIGestureRecognizer
@property(nonatomic, assign) FabricHost* fabric;
@property(nonatomic, weak) RNIKeyboardProxy* keyboard;
@end

@implementation RNITouchForwarder {
  __weak UITouch* _tracked;
}
- (instancetype)init {
  if ((self = [super initWithTarget:nil action:nil])) {
    self.cancelsTouchesInView = NO;
    self.delaysTouchesBegan = NO;
    self.delaysTouchesEnded = NO;
  }
  return self;
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  if (_tracked || !_fabric) return;
  UITouch* t = touches.anyObject;
  _tracked = t;
  const CGPoint p = [t locationInView:self.view];
  const int hit = _fabric->beginTouchCapture((float)p.x, (float)p.y);
  const int focused = _fabric->focusTextInputAt((float)p.x, (float)p.y);
  if (focused == 0) _fabric->beginTextSelection((float)p.x, (float)p.y);
  RNIKeyboardProxy* kb = self.keyboard;
  if (focused != 0 && !kb.isFirstResponder) [kb becomeFirstResponder];
  if (focused == 0 && kb.isFirstResponder) [kb resignFirstResponder];
  std::printf("rni-ios: touch_down hit=%d textinput_focus=%d at=%.1f,%.1f\n", hit, focused, p.x, p.y);
  std::fflush(stdout);
  self.state = UIGestureRecognizerStateBegan;
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  UITouch* t = _tracked;
  if (!t || ![touches containsObject:t] || !_fabric) return;
  const CGPoint p = [t locationInView:self.view];
  if (!_fabric->dragTextSelection((float)p.x, (float)p.y)) {
    _fabric->dispatchCapturedMove((float)p.x, (float)p.y);
  }
  self.state = UIGestureRecognizerStateChanged;
}
- (void)finish:(NSSet<UITouch*>*)touches cancelled:(BOOL)cancelled {
  UITouch* t = _tracked;
  if (!t || ![touches containsObject:t]) return;
  _tracked = nil;
  if (_fabric) {
    const CGPoint p = [t locationInView:self.view];
    const int tag = _fabric->endTouchCapture((float)p.x, (float)p.y);
    _fabric->endTextSelectionDrag();
    std::printf("rni-ios: touch_%s tag=%d at=%.1f,%.1f\n", cancelled ? "cancel" : "up", tag, p.x,
                p.y);
    std::fflush(stdout);
  }
  self.state = cancelled ? UIGestureRecognizerStateCancelled : UIGestureRecognizerStateEnded;
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  [self finish:touches cancelled:NO];
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  [self finish:touches cancelled:YES];
}
- (void)reset {
  [super reset];
  _tracked = nil;
}
@end

// ---------------------------------------------------------------------------
@implementation RNIInputBridge {
  FabricHost* _fabric;
  RNITouchForwarder* _touch;
  RNIKeyboardProxy* _keyboard;
  id _keyboardObserver;
}

- (instancetype)initWithFabric:(FabricHost*)fabric {
  if ((self = [super init])) {
    _fabric = fabric;
    _keyboardObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:UIKeyboardDidShowNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification* n) {
                  const CGRect r = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
                  std::printf("rni-ios: keyboard shown height=%.0f\n", r.size.height);
                  std::fflush(stdout);
                }];
  }
  return self;
}

- (void)dealloc {
  [self detach];
  if (_keyboardObserver) [NSNotificationCenter.defaultCenter removeObserver:_keyboardObserver];
}

- (void)attachToView:(UIView*)view {
  [self detach];
  _keyboard = [[RNIKeyboardProxy alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
  _keyboard.fabric = _fabric;
  [view addSubview:_keyboard];
  _touch = [RNITouchForwarder new];
  _touch.fabric = _fabric;
  _touch.keyboard = _keyboard;
  [view addGestureRecognizer:_touch];
  view.userInteractionEnabled = YES;
}

- (void)detach {
  if (_touch) [_touch.view removeGestureRecognizer:_touch];
  if (_keyboard.isFirstResponder) [_keyboard resignFirstResponder];
  [_keyboard removeFromSuperview];
  _touch = nil;
  _keyboard = nil;
}

- (void)syncFocus {
  if (_keyboard.isFirstResponder && !_fabric->hasTextInputFocus()) [_keyboard resignFirstResponder];
}
@end
