#pragma once
// Style-coverage item A2: mixBlendMode and isolation.
#include <cstdlib>
#include <string>

#include <react/renderer/graphics/BlendMode.h>

#include "impeller.h"

namespace rni {

// Impeller blend mode for a CSS mix-blend-mode keyword; normal maps to SourceOver.
ImpellerBlendMode ToImpellerBlend(facebook::react::BlendMode mode);

// Opens a save-layer for the node and its subtree whose paint composites the
// finished group onto the backdrop with `mode`. The layer starts transparent,
// so it is also the isolated group its descendants blend inside. Close with
// one ImpellerDisplayListBuilderRestore.
void BeginBlendGroup(ImpellerDisplayListBuilder builder, ImpellerBlendMode mode);

}  // namespace rni
