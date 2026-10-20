// iOS host: UIKit keyboard notifications -> RN's Keyboard events
// (keyboardWillShow, keyboardDidShow, keyboardWillHide, keyboardDidHide,
// keyboardWillChangeFrame, keyboardDidChangeFrame), in the payload shape RN's
// own iOS RCTKeyboardObserver sends: startCoordinates and endCoordinates
// ({screenX, screenY, width, height}), duration (ms), easing and
// isEventFromThisApp. Coordinates are in the attached view's points, the
// engine's layout space (the screen's, for a full-screen view), so
// KeyboardAvoidingView's "keyboard top minus my frame" sum is right. Platform.OS
// is 'impeller', so RN's Keyboard module listens on the device event emitter
// directly (Keyboard.js: no native observer off iOS) and these arrive through
// DeviceEventSink. Main thread. Internal to RNIEngine.mm.
#pragma once

#import <UIKit/UIKit.h>

#include <memory>

namespace rni {
class DeviceEventSink;
}

@interface RNIKeyboardEvents : NSObject
- (instancetype)initWithSink:(std::shared_ptr<rni::DeviceEventSink>)sink;
- (void)attachToView:(UIView*)view;
- (void)detach;
@end
