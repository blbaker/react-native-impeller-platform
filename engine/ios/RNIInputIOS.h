// iOS Phase 4 spike: UIKit touches and the system keyboard into the engine.
// Internal to RNIEngine.mm (Objective-C++); apps never include it.
//
// Touch: a UIGestureRecognizer on the attached view forwards the FIRST touch, in
// points, in the desktop windowed host's order (engine/host/main.cpp, the mouse
// button handler): Down -> beginTouchCapture + focusTextInputAt; Move ->
// dispatchCapturedMove + dragTextSelection; Up -> endTouchCapture +
// endTextSelectionDrag. It never cancels or delays UIKit's own touch delivery.
//
// Keyboard: a hidden UITextInput view (RNITextInputView.h) becomes first
// responder when a press focuses a TextInput, which brings up the system
// keyboard configured from the field's props (autoCapitalize, autoCorrect,
// keyboardType, returnKeyType, ...), and resigns when focus leaves. The full
// protocol gives the keyboard the text around the caret, so autocorrect and
// marked text (IME composition) work; every edit reaches the engine as a range
// replace.
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
