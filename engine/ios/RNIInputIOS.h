// iOS Phase 4 spike: UIKit touches and the system keyboard into the engine.
// Internal to RNIEngine.mm (Objective-C++); apps never include it.
//
// Touch: a UIGestureRecognizer on the attached view forwards the FIRST touch, in
// points, in the desktop windowed host's order (engine/host/main.cpp, the mouse
// button handler): Down -> beginTouchCapture + focusTextInputAt; Move ->
// dispatchCapturedMove + dragTextSelection; Up -> endTouchCapture +
// endTextSelectionDrag. It never cancels or delays UIKit's own touch delivery.
//
// Keyboard: a hidden UIView <UIKeyInput> becomes first responder when a press
// focuses a TextInput, which brings up the system keyboard, and resigns when
// focus leaves. insertText -> KeyAction::InsertChar per Unicode scalar
// ("\n" -> Submit), deleteBackward -> Backspace. Plain keys only: no marked text
// (IME), autocorrect, autocapitalisation or selection UI yet (UITextInput is the
// next step), so those traits are switched off rather than half-working.
// All main thread.
#pragma once

#import <UIKit/UIKit.h>

namespace rni {
class FabricHost;
}

@interface RNIInputBridge : NSObject
- (instancetype)initWithFabric:(rni::FabricHost*)fabric;
- (void)attachToView:(UIView*)view;
- (void)detach;
// Once per frame: resign the keyboard when JS blurred the field.
- (void)syncFocus;
@end
