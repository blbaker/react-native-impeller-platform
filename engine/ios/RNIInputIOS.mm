// iOS Phase 4 spike: see RNIInputIOS.h. Built with -fobjc-arc.
#import "ios/RNIInputIOS.h"
#import "ios/RNITextInputView.h"

#import <UIKit/UIGestureRecognizerSubclass.h>

#include <cstdio>

#include "fabric/FabricHost.h"

static_assert(__has_feature(objc_arc), "RNIInputIOS.mm must be built with -fobjc-arc");

using rni::FabricHost;

// ---------------------------------------------------------------------------
// Touch: forwards the first touch without cancelling or delaying UIKit's.
@interface RNITouchForwarder : UIGestureRecognizer
@property(nonatomic, assign) FabricHost* fabric;
@property(nonatomic, weak) RNITextInputView* keyboard;
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
  RNITextInputView* kb = self.keyboard;
  if (focused != 0 && !kb.isFirstResponder) {
    [kb loadFromEngine];  // text, selection and traits before the keyboard comes up
    [kb becomeFirstResponder];
  } else if (focused != 0) {
    [kb syncFromEngine];  // another field, or the caret moved
  }
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
  RNITextInputView* _keyboard;
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
  _keyboard = [[RNITextInputView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
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
  if (_keyboard.isFirstResponder && !_fabric->hasTextInputFocus()) {
    [_keyboard resignFirstResponder];
    return;
  }
  [_keyboard syncFromEngine];
}
@end
