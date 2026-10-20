// A TextInput's keyboard traits, as a host's system keyboard needs them (the
// iOS host's UITextInputTraits). Copied from RN's iOS TextInputProps::traits
// (react/renderer/components/iostextinput/primitives.h) at mount time. The
// enums are stored as their RN integer values, so this header needs no RN
// include; hosts cast back to react::AutocapitalizationType, KeyboardType,
// ReturnKeyType and KeyboardAppearance.
#pragma once

namespace rni {

struct TextInputKeyboardTraits {
  int autoCapitalize{2};  // react::AutocapitalizationType (RN default: Sentences)
  int autoCorrect{-1};    // -1 unset (platform default), 0 off, 1 on
  int spellCheck{-1};     // -1 unset, 0 off, 1 on
  int keyboardType{0};    // react::KeyboardType
  int returnKeyType{0};   // react::ReturnKeyType
  int keyboardAppearance{0};  // react::KeyboardAppearance
  bool enablesReturnKeyAutomatically{false};
  bool secure{false};
  bool multiline{false};
};

}  // namespace rni
