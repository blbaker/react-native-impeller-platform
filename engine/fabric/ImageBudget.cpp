// FP-33: cache budget, low-memory purge and the per-frame test hook. See ImageCache.h.
#include <atomic>
#include <cstdio>
#include <mutex>

#include "ImageCache.h"
#include "ImageInternal.h"

namespace rni::image {
namespace {

std::mutex gListenerMutex;
std::function<void()> gListener;
std::atomic<int> gPurges{0}, gReloads{0}, gTextures{0};

}  // namespace

void SetCacheBudget(int64_t bytes) { Cache().SetBudget(bytes); }
void SetCacheFloor(int64_t bytes) { Cache().SetFloor(bytes); }
int64_t CacheBytes() { return Cache().Bytes(); }
bool IsResident(const Decoded* d) { return Cache().IsResident(d); }
uint64_t EvictionEpoch() { return Cache().Epoch(); }

void SetPurgeListener(std::function<void()> fn) {
  std::lock_guard<std::mutex> lock(gListenerMutex);
  gListener = std::move(fn);
}

// Flutter: WidgetsBinding.didHaveMemoryPressure -> imageCache.clear().
void HandleLowMemory(const char* source) {
  const int64_t before = Cache().Bytes();
  const int64_t freed = Cache().Purge();
  ClearFetchedBodies();
  std::printf("rn-impeller: low_memory source=%s purge=%d image_cache_bytes_before=%lld "
              "image_cache_bytes_after=%lld freed=%lld\n",
              source, gPurges.fetch_add(1) + 1, (long long)before, (long long)Cache().Bytes(),
              (long long)freed);
  std::fflush(stdout);
  std::function<void()> wake;
  {
    std::lock_guard<std::mutex> lock(gListenerMutex);
    wake = gListener;
  }
  if (wake) wake();
}

void OnFrame() {
  static std::atomic<int> frame{0};
  static const int at = EnvInt("RNI_TEST_LOW_MEMORY_AT_FRAME");
  if (frame.fetch_add(1) + 1 == at && at > 0) HandleLowMemory("test");
}

void AddLiveTextures(int delta) { gTextures.fetch_add(delta); }

void PrintCacheStats() {
  std::printf("rn-impeller: image_cache bytes=%lld peak=%lld evictions=%llu reloads=%d purges=%d textures_live=%d\n",
              (long long)Cache().Bytes(), (long long)Cache().Peak(),
              (unsigned long long)Cache().Epoch(), gReloads.load(), gPurges.load(), gTextures.load());
}

void Reload(const std::string& uri, float boxW, float boxH, std::function<void()> done) {
  Headers headers;
  Cache().Seen(uri, &headers);
  gReloads.fetch_add(1);
  LoadAsync(uri, headers, boxW, boxH, [done = std::move(done)](const LoadResult&) {
    if (done) done();
  });
}

}  // namespace rni::image

// Android: ImpellerRenderer.onTrimMemory reaches this through a weak reference, so the smoke-test
// library (which does not link the image store) still builds.
extern "C" void rni_handle_low_memory(const char* source) { rni::image::HandleLowMemory(source); }
