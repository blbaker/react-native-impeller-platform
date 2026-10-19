// iOS host: the first responder the system keyboard edits (UITextInput). It
// keeps a copy of the focused TextInput's text and selection (UTF-16, as UIKit
// counts), applies each keyboard edit to that copy, and sends it to the engine
// as a range replace (FabricHost::replaceTextInputRange); the engine's edit
// buffer stays the source of truth, and changes the engine makes on its own (a
// submit, a JS value update) come back through syncFromEngine. With the full
// protocol the keyboard can read the text around the caret, so autocorrect,
// predictive text and marked text (IME composition) work. Main thread only.
// Internal to RNIInputIOS.mm; apps never include it.
#pragma once

#import <UIKit/UIKit.h>

namespace rni {
class FabricHost;
}

@interface RNITextInputView : UIView <UITextInput>
@property(nonatomic, assign) rni::FabricHost* fabric;
// Read the focused field (text, selection, keyboard traits) from the engine.
// Call before becomeFirstResponder, so the keyboard comes up configured.
- (void)loadFromEngine;
// Once per frame while first responder: pick up what the engine changed on
// its own (focus moved to another field, a submit, a JS value update) and tell
// the keyboard. Never during a composition.
- (void)syncFromEngine;
@end
