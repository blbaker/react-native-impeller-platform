#include "base/ContextFlags.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>

namespace rni::contextflags {
namespace {
// -1 = not set by the CLI, then RNI_SDF_AA decides.
std::atomic<int> gSdfAa{-1};
}  // namespace

void SetSdfAa(bool on) { gSdfAa.store(on ? 1 : 0); }

bool SdfAaRequested() {
  int v = gSdfAa.load();
  if (v >= 0) return v == 1;
  const char* env = std::getenv("RNI_SDF_AA");
  return env != nullptr && env[0] == '1';
}

void ApplyBeforeCreate() {
#ifdef IMPELLER_RNI_CONTEXT_FLAGS
  ImpellerContextSetDefaultFlags(SdfAaRequested() ? kImpellerContextFlagUseSDFs : 0u);
#endif
}

void Report(ImpellerContext context) {
  const char* requested = SdfAaRequested() ? "on" : "off";
#ifdef IMPELLER_RNI_CONTEXT_FLAGS
  bool on = context != nullptr &&
            (ImpellerContextGetFlags(context) & kImpellerContextFlagUseSDFs) != 0;
  fprintf(stderr, "context_flags sdf_aa=%s requested=%s sdk=0003\n", on ? "on" : "off", requested);
#else
  (void)context;
  fprintf(stderr, "context_flags sdf_aa=off requested=%s sdk=none\n", requested);
#endif
}

}  // namespace rni::contextflags
