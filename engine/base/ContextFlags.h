// FP-22: impeller::Flags for the contexts the host creates (SDK patch 0003,
// engine/impeller-sdk-patches/0003-rni-context-flags.patch). Upstream interop
// hard-codes Flags{} (toolkit/interop/backend/gles/context_gles.cc), so
// use_sdfs (impeller/base/flags.h) is unreachable without the patch.
#pragma once

#include "impeller.h"

namespace rni::contextflags {

// --sdf-aa on|off. Unset: RNI_SDF_AA=1 turns it on (Android has no CLI). Default off.
void SetSdfAa(bool on);
bool SdfAaRequested();

// Call immediately before ImpellerContextCreate*New.
void ApplyBeforeCreate();

// Call immediately after: prints `context_flags sdf_aa=on|off requested=on|off
// sdk=0003|none`, sdf_aa read back from the created context.
void Report(ImpellerContext context);

}  // namespace rni::contextflags
