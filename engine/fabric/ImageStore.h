#pragma once

// A19 (SC-30): decoded <Image> sources, shared by the Fabric ImageManager
// (requests decodes) and the painter (reads pixels). Local sources: data: URIs
// (base64 or percent-encoded), file:// URLs and absolute paths. SC-31: http(s)
// sources load through the host's fetcher (NetworkingModule's transport).
// FP-16 (model: Flutter's IO runner + ImageDecoderImpeller,
// lib/ui/painting/image_decoder_impeller.cc): every decode runs on one fixed
// pool of DecodePoolSize() threads, sized for the <Image> box and clamped to
// the max texture size; fetches run on a second fixed pool. The cache is keyed
// by URI + size bucket; concurrent requests for one key share one decode.

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace rni::image {

struct Decoded {
  int width{0};  // pixels in `rgba` (the decode size)
  int height{0};
  int srcWidth{0};  // the encoded image's own size (onLoad, getSize, natural size)
  int srcHeight{0};
  // Tightly packed RGBA8, PREMULTIPLIED (Impeller samples premultiplied).
  std::vector<uint8_t> rgba;
};

using Headers = std::vector<std::pair<std::string, std::string>>;

bool IsRemote(const std::string& uri);

// True when any size of `uri` is decoded and cached.
bool IsCached(const std::string& uri);

// The painter's view of the cache for a box in pixels. `image` is the exact
// size bucket if cached, else the best cached size of the URI. `failed`: this
// bucket failed to decode. `pending`: nothing cached yet but a load is running.
struct Lookup {
  std::shared_ptr<const Decoded> image;
  bool failed{false};
  bool pending{false};
  bool evicted{false};  // FP-33: nothing cached, but the URI was and the budget or a purge dropped it
};
Lookup Find(const std::string& uri, float boxW, float boxH);

// Decodes a LOCAL uri on the calling thread into the cache (for sources no
// request covers, e.g. defaultSource). Null for remote or undecodable sources.
std::shared_ptr<const Decoded> DecodeNow(const std::string& uri, float boxW, float boxH);

// One HTTP GET as the host performs it. `ok` is false on a transport error or
// a non-2xx status (then `error` says why and `status` is the HTTP code or 0).
struct FetchResult {
  bool ok{false};
  std::string error;
  int status{0};
  Headers headers;
  std::string body;
};
using Fetcher = std::function<FetchResult(const std::string& uri, const Headers& headers)>;

// Installed by the host. `begin`/`end` bracket every remote load (fetch, decode
// and the completion callbacks) so a headless run can wait for images.
void SetFetcher(Fetcher fetch, std::function<void()> begin, std::function<void()> end);

struct LoadResult {
  std::shared_ptr<const Decoded> image;  // null on failure
  std::string error;
  int status{0};
  Headers headers;
};
using LoadDone = std::function<void(const LoadResult&)>;

// Cached results complete inline (returns 0). Otherwise the decode (after a
// fetch for remote URIs) runs on the pool and `done` runs there; the returned
// ticket cancels it. `owner`, when set, cancels implicitly once it expires.
// Remote failures are not cached, so a later load retries. boxW/boxH: target
// box in pixels, 0 = unknown.
uint64_t LoadAsync(const std::string& uri, const Headers& headers, float boxW, float boxH,
                   LoadDone done, const std::shared_ptr<const void>& owner = nullptr);
inline void LoadAsync(const std::string& uri, const Headers& headers, LoadDone done) {
  LoadAsync(uri, headers, 0.0f, 0.0f, std::move(done));
}

// Drops one waiter; a decode nobody waits for any more is skipped.
void Cancel(uint64_t ticket);

// Queried once per GPU context by the host (GL_MAX_TEXTURE_SIZE). Default 8192.
// RNI_TEST_MAX_TEXTURE_SIZE overrides it.
void SetMaxTextureSize(int px);
int MaxTextureSize();

// FP-33 memory budget (model: Flutter's ImageCache, image_cache.dart). Decoded bitmaps (and the
// textures made from them) live in an LRU capped at `--image-cache-mb` (default 100, Flutter's
// _kDefaultSizeBytes). A low-memory signal purges it down to the floor (default 0, Flutter's clear()).
void SetCacheBudget(int64_t bytes);
void SetCacheFloor(int64_t bytes);
int64_t CacheBytes();
// Any thread. `source` names the signal in the `low_memory` log line.
void HandleLowMemory(const char* source);
// Called by the host once per painted frame: fires RNI_TEST_LOW_MEMORY_AT_FRAME.
void OnFrame();
// The painter's texture for a bitmap is valid only while the bitmap is resident; the epoch moves
// on every eviction so a sweep can be skipped when nothing was evicted.
bool IsResident(const Decoded* d);
uint64_t EvictionEpoch();
// Runs on any thread after a purge, so the scene can repaint.
void SetPurgeListener(std::function<void()> fn);
// Starts the load of an evicted URI again (same headers as before); `done` runs when it ends.
// The painter reports the textures it holds (uploaded minus released) for the stats line.
void AddLiveTextures(int delta);
void PrintCacheStats();  // `image_cache bytes= peak= evictions= reloads= purges= textures_live=`
void Reload(const std::string& uri, float boxW, float boxH, std::function<void()> done);

// Blocks until no decode or fetch is queued or running, up to timeoutMs.
// Returns true if anything was in flight when called.
bool WaitIdle(int timeoutMs);

// Prints `image_io pool= threads= jobs= decodes= peak_live= dedup= canceled= sync= max_texture=`.
void PrintStats();

// FP-06: teardown fence. A remote completion's waiters dispatch RN events (onLoad) from the
// fetch thread; ~FabricHost calls StopCallbacks() before stopSurface's empty-tree commit, so no
// waiter reads an EventEmitter while that commit unmounts it. Completions after it are dropped.
// StartCallbacks() re-arms delivery (FabricHost's constructor).
void StopCallbacks();
void StartCallbacks();

// FP-17 (model: ImageDecoderImpeller::UploadTextureToPrivate): when set, a
// successful pool decode is handed to `hook(image, done)` and the load completes
// (cache insert, waiters) only when `done` runs, after the GPU upload. `done`
// must run exactly once, on any thread. Null restores immediate completion.
using UploadHook = void (*)(std::shared_ptr<const Decoded> image, std::function<void()> done);
void SetUploadHook(UploadHook hook);

// Exposed for tests: the bytes a local URI names, or false.
bool ReadSourceBytes(const std::string& uri, std::vector<uint8_t>& out);

}  // namespace rni::image
