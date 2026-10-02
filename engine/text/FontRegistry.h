#pragma once
// ENG-22: app font files registered with the Impeller typography context, so a
// <Text style={{fontFamily}}> that names a face the OS does not ship (Geist
// Mono on a fresh box, any bundled app font) paints that face instead of the
// fallback.
//
// Sources, in order: every `--font-dir DIR` on the command line, then every
// entry of RNI_FONT_DIRS (':'-separated, ';' on Windows). Each .ttf/.otf/.ttc file directly
// inside a dir is registered under the family name stored IN the font (no
// alias), which is the same name RN passes through TextAttributes::fontFamily.
//
// Must run right after the surface creates its typography context and BEFORE
// FabricHost mounts anything: measure (ImpellerTextLayoutManager) and paint
// (SceneGraph) share this one context, and a face registered after the first
// measure would leave already-measured boxes sized for the fallback.
#include <impeller.h>

#include <string>
#include <vector>

namespace rni {

// Prints one `rn-impeller: font_registered=<path> ok=<0|1>` line per file and
// returns the number registered successfully.
int RegisterFontDirs(ImpellerTypographyContext typography,
                     const std::vector<std::string>& dirs);

// The dirs RegisterFontDirs would read: `cliDirs` then RNI_FONT_DIRS.
std::vector<std::string> FontDirsFrom(const std::vector<std::string>& cliDirs);

}  // namespace rni
