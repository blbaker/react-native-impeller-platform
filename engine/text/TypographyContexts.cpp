#include "text/TypographyContexts.h"

#include <atomic>
#include <cstdio>
#include <mutex>

namespace rni::typography {
namespace {

struct Font {
  std::string path;
  std::shared_ptr<const std::vector<uint8_t>> bytes;
};

std::mutex gMu;
std::vector<Font> gFonts;  // guarded by gMu; append-only
std::atomic<size_t> gCount{0};
std::atomic<size_t> gBound{0};
std::atomic<size_t> gOwn{0};
std::atomic<uint64_t> gGeneration{0};  // FP-32: bumped by Invalidate()
std::atomic<size_t> gRebuilt{0};

// Impeller owns the mapping until on_release; the bytes are shared between contexts.
struct Blob {
  std::shared_ptr<const std::vector<uint8_t>> bytes;
  ImpellerMapping mapping{};
};
void ReleaseBlob(void* user) { delete static_cast<Blob*>(user); }

struct Slot {
  ImpellerTypographyContext ctx = nullptr;
  bool owned = false;
  size_t applied = 0;
  uint64_t generation = 0;
  std::vector<bool> ok;
  ~Slot() {
    if (owned && ctx != nullptr) ImpellerTypographyContextRelease(ctx);
  }
};

thread_local Slot tSlot;

// Registers into the slot's context every font added since its last sync.
void Sync(Slot& slot) {
  if (slot.ctx == nullptr || slot.applied == gCount.load(std::memory_order_acquire)) return;
  std::vector<Font> fresh;
  {
    std::lock_guard<std::mutex> lock(gMu);
    fresh.assign(gFonts.begin() + (std::ptrdiff_t)slot.applied, gFonts.end());
  }
  for (const Font& f : fresh) {
    auto* blob = new Blob{f.bytes, {}};
    blob->mapping.data = blob->bytes->data();
    blob->mapping.length = blob->bytes->size();
    blob->mapping.on_release = &ReleaseBlob;
    // Ownership passes to Impeller here, success or not.
    slot.ok.push_back(
        ImpellerTypographyContextRegisterFont(slot.ctx, &blob->mapping, blob, nullptr));
  }
  slot.applied += fresh.size();
}

}  // namespace

ImpellerTypographyContext ForThisThread() {
  Slot& slot = tSlot;
  const uint64_t gen = gGeneration.load(std::memory_order_acquire);
  if (slot.owned && slot.ctx != nullptr && slot.generation != gen) {  // FP-32
    ImpellerTypographyContextRelease(slot.ctx);
    slot.ctx = nullptr;
    slot.owned = false;
    slot.applied = 0;
    slot.ok.clear();
    gRebuilt.fetch_add(1, std::memory_order_relaxed);
  }
  if (slot.ctx == nullptr) {
    slot.generation = gen;
    slot.ctx = ImpellerTypographyContextNew();
    slot.owned = slot.ctx != nullptr;
    if (slot.owned) gOwn.fetch_add(1, std::memory_order_relaxed);
  }
  Sync(slot);
  return slot.ctx;
}

void Bind(ImpellerTypographyContext ctx) {
  Slot& slot = tSlot;
  if (slot.owned && slot.ctx != nullptr) ImpellerTypographyContextRelease(slot.ctx);
  slot.ctx = ctx;
  slot.owned = false;
  slot.generation = gGeneration.load(std::memory_order_acquire);
  gBound.fetch_add(1, std::memory_order_relaxed);
  slot.applied = 0;
  slot.ok.clear();
  Sync(slot);
}

void Unbind(ImpellerTypographyContext ctx) {
  Slot& slot = tSlot;
  if (slot.ctx != ctx || slot.owned) return;
  slot.ctx = nullptr;
  slot.applied = 0;
  slot.ok.clear();
}

void Invalidate() { gGeneration.fetch_add(1, std::memory_order_acq_rel); }

size_t AddFont(const std::string& path, std::shared_ptr<const std::vector<uint8_t>> bytes) {
  std::lock_guard<std::mutex> lock(gMu);
  gFonts.push_back({path, std::move(bytes)});
  gCount.store(gFonts.size(), std::memory_order_release);
  return gFonts.size() - 1;
}

uint64_t FontEpoch() {
  return (gGeneration.load(std::memory_order_acquire) << 32) +
         (uint64_t)gCount.load(std::memory_order_acquire);
}

bool RegisteredHere(size_t index) {
  ForThisThread();
  return index < tSlot.ok.size() && tSlot.ok[index];
}

void PrintSummary() {
  printf("rn-impeller: typography_contexts bound=%zu own=%zu fonts=%zu\n", gBound.load(),
         gOwn.load(), gCount.load());
  if (gGeneration.load() > 0) {
    printf("rn-impeller: typography_rebuild generations=%llu own_rebuilt=%zu\n",
           (unsigned long long)gGeneration.load(), gRebuilt.load());
  }
  fflush(stdout);
}

}  // namespace rni::typography
