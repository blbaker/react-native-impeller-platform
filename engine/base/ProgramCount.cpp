#include "base/ProgramCount.h"

#include <atomic>
#include <cstdio>
#include <cstring>

namespace rni::programcount {

namespace {
std::atomic<int> gPhase{0};
std::atomic<uint64_t> gLinked[3];
using LinkFn = void (*)(unsigned int);
LinkFn gRealLink = nullptr;

void CountingLink(unsigned int program) {
  gLinked[gPhase.load(std::memory_order_relaxed)].fetch_add(1, std::memory_order_relaxed);
  if (gRealLink) gRealLink(program);
}
}  // namespace

void* Wrap(const char* name, void* real) {
  if (real == nullptr || std::strcmp(name, "glLinkProgram") != 0) return real;
  gRealLink = reinterpret_cast<LinkFn>(real);
  return reinterpret_cast<void*>(&CountingLink);
}

void SetPhase(Phase phase) { gPhase.store(static_cast<int>(phase), std::memory_order_relaxed); }

uint64_t Linked(Phase phase) {
  return gLinked[static_cast<int>(phase)].load(std::memory_order_relaxed);
}

void PrintSummary() {
  std::printf("rn-impeller: programs startup=%llu tour=%llu frames=%llu\n",
              (unsigned long long)Linked(Phase::kStartup), (unsigned long long)Linked(Phase::kTour),
              (unsigned long long)Linked(Phase::kFrames));
  std::fflush(stdout);
}

}  // namespace rni::programcount
