#pragma once
// SC-18: one fontFamily string -> the single family name handed to Impeller.
// The package joins array values into a CSS stack ("a, b, c"); this picks the
// first entry that resolves and maps generic names (monospace, serif,
// sans-serif, system-ui, ui-*) to a concrete face for the OS. Measure and
// paint both call it, so they cannot disagree.
#include <string>

namespace rni {

std::string ResolveFontFamily(const std::string& stack);

// Linux: lets the resolver see faces registered from --font-dir / RNI_FONT_DIRS.
void NoteAppFontDir(const std::string& dir);

}  // namespace rni
