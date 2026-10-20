// iOS host: see RNIKeyboardEventsIOS.h. Built with -fobjc-arc.
#import "ios/RNIKeyboardEventsIOS.h"

#include <cstdio>
#include <string>

#include "runtime/DeviceEventSink.h"

static_assert(__has_feature(objc_arc), "RNIKeyboardEventsIOS.mm must be built with -fobjc-arc");

// As RN's RCTKeyboardObserver names a UIKit animation curve.
static const char* EasingFor(NSInteger curve) {
  switch ((UIViewAnimationCurve)curve) {
    case UIViewAnimationCurveEaseIn: return "easeIn";
    case UIViewAnimationCurveEaseInOut: return "easeInEaseOut";
    case UIViewAnimationCurveEaseOut: return "easeOut";
    case UIViewAnimationCurveLinear: return "linear";
    default: return "keyboard";  // the keyboard's own curve (7)
  }
}

static folly::dynamic Coordinates(CGRect r) {
  return folly::dynamic::object("screenX", (double)r.origin.x)("screenY", (double)r.origin.y)(
      "width", (double)r.size.width)("height", (double)r.size.height);
}

@implementation RNIKeyboardEvents {
  std::shared_ptr<rni::DeviceEventSink> _sink;
  __weak UIView* _view;
  NSMutableArray<id>* _observers;
}

- (instancetype)initWithSink:(std::shared_ptr<rni::DeviceEventSink>)sink {
  if ((self = [super init])) {
    _sink = std::move(sink);
    _observers = [NSMutableArray new];
  }
  return self;
}

- (void)dealloc {
  [self detach];
}

- (void)attachToView:(UIView*)view {
  [self detach];
  _view = view;
  NSDictionary<NSNotificationName, NSString*>* names = @{
    UIKeyboardWillShowNotification : @"keyboardWillShow",
    UIKeyboardDidShowNotification : @"keyboardDidShow",
    UIKeyboardWillHideNotification : @"keyboardWillHide",
    UIKeyboardDidHideNotification : @"keyboardDidHide",
    UIKeyboardWillChangeFrameNotification : @"keyboardWillChangeFrame",
    UIKeyboardDidChangeFrameNotification : @"keyboardDidChangeFrame",
  };
  __weak RNIKeyboardEvents* weakSelf = self;
  for (NSNotificationName note in names) {
    NSString* rnName = names[note];
    [_observers addObject:[NSNotificationCenter.defaultCenter
                              addObserverForName:note
                                          object:nil
                                           queue:NSOperationQueue.mainQueue
                                      usingBlock:^(NSNotification* n) {
                                        [weakSelf emit:rnName userInfo:n.userInfo];
                                      }]];
  }
}

- (void)detach {
  for (id o in _observers) [NSNotificationCenter.defaultCenter removeObserver:o];
  [_observers removeAllObjects];
  _view = nil;
}

- (void)emit:(NSString*)name userInfo:(NSDictionary*)info {
  UIView* view = _view;
  if (!_sink || !view) return;
  CGRect begin = [info[UIKeyboardFrameBeginUserInfoKey] CGRectValue];
  CGRect end = [info[UIKeyboardFrameEndUserInfoKey] CGRectValue];
  // UIKit reports the keyboard in screen coordinates; the engine lays out in
  // the attached view's.
  if (view.window) {
    id<UICoordinateSpace> screen = view.window.screen.coordinateSpace;
    begin = [view convertRect:begin fromCoordinateSpace:screen];
    end = [view convertRect:end fromCoordinateSpace:screen];
  }
  const double durationMs = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue] * 1000.0;
  const char* easing = EasingFor([info[UIKeyboardAnimationCurveUserInfoKey] integerValue]);
  const bool local = [info[UIKeyboardIsLocalUserInfoKey] boolValue];
  folly::dynamic payload = folly::dynamic::object("startCoordinates", Coordinates(begin))(
      "endCoordinates", Coordinates(end))("duration", durationMs)("easing", easing)(
      "isEventFromThisApp", local);
  std::printf("rni-ios: keyboard_event %s end=%.0f,%.0f,%.0fx%.0f duration=%.0f easing=%s\n",
              name.UTF8String, end.origin.x, end.origin.y, end.size.width, end.size.height,
              durationMs, easing);
  std::fflush(stdout);
  _sink->emit(name.UTF8String, payload);
}

@end
