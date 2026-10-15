#include "ImageStore.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <unordered_map>

#include "ImageInternal.h"
#include "ImageIoPool.h"
#include "ImageResize.h"

namespace rni::image {
namespace {

struct Waiter {
  uint64_t id;
  LoadDone done;
  std::weak_ptr<const void> owner;
  bool owned;
};

struct Job {
  std::string key, uri, sizeKey;
  Headers headers;
  int boxW{0}, boxH{0};
  bool remote{false}, fetches{false}, started{false}, canceled{false};
  std::vector<Waiter> waiters;
  std::string body;  // remote: the encoded bytes
  int status{0};
  Headers responseHeaders;
};

std::mutex gMutex;
std::condition_variable gIdle;
// uri -> size bucket -> decoded. A failed LOCAL decode maps to null so the painter does not retry it.
std::unordered_map<std::string, std::unordered_map<std::string, std::shared_ptr<const Decoded>>> gCache;
std::unordered_map<std::string, std::shared_ptr<Job>> gPending;  // key -> the one job for it
std::unordered_map<std::string, int> gPendingUri;
std::unordered_map<uint64_t, std::shared_ptr<Job>> gTickets;
uint64_t gNextTicket = 0;
int gInFlight = 0, gJobs = 0, gDedup = 0, gCanceled = 0;
std::atomic<int> gSync{0};
// FP-06 teardown fence: completions that finish after StopCallbacks() drop their waiters;
// StopCallbacks() returns only once no completion callback is still running.
bool gCallbacksStopped = false;
int gCallbacksRunning = 0;
std::condition_variable gCallbacksIdle;

IoPool& DecodePool() {
  static IoPool* pool = new IoPool("rni-image-io", DecodePoolSize());
  return *pool;
}
IoPool& NetPool() {
  static IoPool* pool = new IoPool("rni-image-net", 4);
  return *pool;
}

std::string SizeKey(int bw, int bh) { return std::to_string(bw) + "x" + std::to_string(bh); }

// --- under gMutex ---
void ErasePending(const std::shared_ptr<Job>& job) {
  auto it = gPending.find(job->key);
  if (it == gPending.end() || it->second != job) return;
  gPending.erase(it);
  if (--gPendingUri[job->uri] <= 0) gPendingUri.erase(job->uri);
}
std::vector<Waiter> TakeWaiters(Job& job) {
  for (const Waiter& w : job.waiters) gTickets.erase(w.id);
  return std::move(job.waiters);
}
// ---

// Drops cancelled and expired waiters; false (and the job is dropped) when none is left.
bool Start(const std::shared_ptr<Job>& job) {
  std::lock_guard<std::mutex> lock(gMutex);
  auto& w = job->waiters;
  w.erase(std::remove_if(w.begin(), w.end(),
                         [](const Waiter& x) {
                           const bool gone = x.owned && x.owner.expired();
                           if (gone) gTickets.erase(x.id);
                           return gone;
                         }),
          w.end());
  if (!job->canceled && !w.empty()) {
    job->started = true;
    return true;
  }
  job->canceled = true;
  ErasePending(job);
  ++gCanceled;
  return false;
}

void Complete(const std::shared_ptr<Job>& job, const LoadResult& r, bool cache) {
  std::vector<Waiter> waiters;
  {
    std::lock_guard<std::mutex> lock(gMutex);
    if (cache) gCache[job->uri][job->sizeKey] = r.image;
    waiters = TakeWaiters(*job);
    ErasePending(job);
    if (gCallbacksStopped) waiters.clear();
    else if (!waiters.empty()) ++gCallbacksRunning;
  }
  if (waiters.empty()) return;
  for (auto& w : waiters) {
    if (!w.owned || !w.owner.expired()) w.done(r);
  }
  std::lock_guard<std::mutex> lock(gMutex);
  if (--gCallbacksRunning == 0) gCallbacksIdle.notify_all();
}

void Finish(const std::shared_ptr<Job>& job) {
  std::function<void()> end;
  {
    std::lock_guard<std::mutex> lock(gMutex);
    ErasePending(job);
    --gInFlight;
  }
  gIdle.notify_all();
  if (job->fetches) FetchBracket(nullptr, &end);
  if (end) end();
}

void DecodeJob(const std::shared_ptr<Job>& job) {
  if (!job->started && !Start(job)) return Finish(job);
  LoadResult r;
  std::vector<uint8_t> local;
  if (job->remote) {
    r.image = RunDecode((const uint8_t*)job->body.data(), job->body.size(), job->boxW, job->boxH, job->uri);
    r.status = job->status;
    r.headers = job->responseHeaders;
    if (!r.image) r.error = "could not decode the image at " + job->uri;
  } else {
    if (ReadSourceBytes(job->uri, local)) r.image = RunDecode(local.data(), local.size(), job->boxW, job->boxH, job->uri);
    if (!r.image) r.error = "could not load " + job->uri;
  }
  Complete(job, r, r.image || !job->remote);
  Finish(job);
}

void FetchJob(const std::shared_ptr<Job>& job) {
  if (!Start(job)) return Finish(job);
  FetchResult f = FetchShared(job->uri, job->headers);
  job->status = f.status;
  job->responseHeaders = std::move(f.headers);
  if (!f.ok || f.body.empty()) {
    LoadResult r;
    r.status = job->status;
    r.headers = job->responseHeaders;
    r.error = !f.ok ? (f.error.empty() ? "request failed" : f.error)
                    : "could not decode the image at " + job->uri;
    Complete(job, r, false);
    return Finish(job);
  }
  job->body = std::move(f.body);
  DecodePool().Post([job] { DecodeJob(job); });
}

}  // namespace

bool IsCached(const std::string& uri) {
  std::lock_guard<std::mutex> lock(gMutex);
  auto u = gCache.find(uri);
  if (u == gCache.end()) return false;
  for (const auto& [k, d] : u->second) if (d) return true;
  return false;
}

Lookup Find(const std::string& uri, float boxW, float boxH) {
  int bw = SizeBucket(boxW), bh = SizeBucket(boxH);
  if (bw == 0 || bh == 0) bw = bh = 0;
  Lookup l;
  std::lock_guard<std::mutex> lock(gMutex);
  auto u = gCache.find(uri);
  if (u != gCache.end()) {
    auto s = u->second.find(SizeKey(bw, bh));
    if (s != u->second.end()) {
      l.image = s->second;
      l.failed = !s->second;
      return l;
    }
    // Another size of this URI: the smallest that covers the box, else the largest.
    for (const auto& [k, d] : u->second) {
      if (!d) continue;
      const bool covers = d->width >= boxW && d->height >= boxH;
      const bool bestCovers = l.image && l.image->width >= boxW && l.image->height >= boxH;
      const long long area = (long long)d->width * d->height;
      const long long best = l.image ? (long long)l.image->width * l.image->height : -1;
      if (!l.image || (covers && (!bestCovers || area < best)) || (!covers && !bestCovers && area > best)) {
        l.image = d;
      }
    }
    if (l.image) return l;
  }
  l.pending = gPendingUri.count(uri) > 0;
  return l;
}

std::shared_ptr<const Decoded> DecodeNow(const std::string& uri, float boxW, float boxH) {
  if (IsRemote(uri)) return nullptr;
  int bw = SizeBucket(boxW), bh = SizeBucket(boxH);
  if (bw == 0 || bh == 0) bw = bh = 0;
  std::vector<uint8_t> bytes;
  std::shared_ptr<const Decoded> d = ReadSourceBytes(uri, bytes) ? RunDecode(bytes.data(), bytes.size(), bw, bh, uri) : nullptr;
  gSync.fetch_add(1);
  std::lock_guard<std::mutex> lock(gMutex);
  return gCache[uri].emplace(SizeKey(bw, bh), d).first->second;
}

uint64_t LoadAsync(const std::string& uri, const Headers& headers, float boxW, float boxH,
                   LoadDone done, const std::shared_ptr<const void>& owner) {
  int bw = SizeBucket(boxW), bh = SizeBucket(boxH);
  if (bw == 0 || bh == 0) bw = bh = 0;  // a box known in one axis only is no box
  const std::string sizeKey = SizeKey(bw, bh), key = uri + "|" + sizeKey;
  std::shared_ptr<const Decoded> hit;
  bool cached = false;
  uint64_t id = 0;
  std::shared_ptr<Job> post;
  std::function<void()> begin;
  {
    std::lock_guard<std::mutex> lock(gMutex);
    auto u = gCache.find(uri);
    if (u != gCache.end()) {
      auto s = u->second.find(sizeKey);
      if (s != u->second.end()) cached = true, hit = s->second;
    }
    if (!cached) {
      id = ++gNextTicket;
      auto& slot = gPending[key];
      if (slot) {
        ++gDedup;
      } else {
        slot = std::make_shared<Job>();
        slot->key = key;
        slot->uri = uri;
        slot->sizeKey = sizeKey;
        slot->headers = headers;
        slot->boxW = bw;
        slot->boxH = bh;
        slot->remote = IsRemote(uri);
        // fetched before (another size): decode the kept body, no second GET
        slot->fetches = slot->remote && !CachedBody(uri, &slot->body);
        if (slot->fetches) FetchBracket(&begin, nullptr);
        ++gPendingUri[uri];
        ++gInFlight;
        ++gJobs;
        post = slot;
      }
      slot->waiters.push_back({id, std::move(done), owner, owner != nullptr});
      gTickets[id] = slot;
    }
  }
  if (cached) {  // `done` runs without the store lock
    LoadResult r;
    r.image = std::move(hit);
    if (!r.image) r.error = "could not load " + uri;
    done(r);
    return 0;
  }
  if (post) {
    if (begin) begin();
    if (post->fetches) NetPool().Post([post] { FetchJob(post); });
    else DecodePool().Post([post] { DecodeJob(post); });
  }
  return id;
}

void Cancel(uint64_t ticket) {
  std::lock_guard<std::mutex> lock(gMutex);
  auto it = gTickets.find(ticket);
  if (it == gTickets.end()) return;
  std::shared_ptr<Job> job = it->second;
  gTickets.erase(it);
  auto& w = job->waiters;
  w.erase(std::remove_if(w.begin(), w.end(), [ticket](const Waiter& x) { return x.id == ticket; }), w.end());
  if (w.empty() && !job->started) {
    job->canceled = true;  // the queued task sees this and skips the decode
    ErasePending(job);
  }
}

bool WaitIdle(int timeoutMs) {
  std::unique_lock<std::mutex> lock(gMutex);
  const bool had = gInFlight > 0;
  gIdle.wait_for(lock, std::chrono::milliseconds(timeoutMs), [] { return gInFlight == 0; });
  return had;
}

void PrintStats() {
  int jobs, dedup, canceled;
  {
    std::lock_guard<std::mutex> lock(gMutex);
    jobs = gJobs, dedup = gDedup, canceled = gCanceled;
  }
  std::printf("rn-impeller: image_io pool=%d threads=%d jobs=%d decodes=%d peak_live=%d dedup=%d "
              "canceled=%d sync=%d max_texture=%d\n",
              DecodePool().size(), DecodePool().started(), jobs, DecodeCount(), PeakLiveDecodes(), dedup,
              canceled, gSync.load(), MaxTextureSize());
#if defined(__linux__)
  if (FILE* f = std::fopen("/proc/self/status", "r")) {
    char line[256];
    while (std::fgets(line, sizeof line, f)) {
      if (std::strncmp(line, "VmHWM:", 6) == 0) std::printf("rn-impeller: rss_peak_kb=%ld\n", std::atol(line + 6));
    }
    std::fclose(f);
  }
#endif
}

void StopCallbacks() {
  std::unique_lock<std::mutex> lock(gMutex);
  gCallbacksStopped = true;
  gCallbacksIdle.wait(lock, [] { return gCallbacksRunning == 0; });
}

void StartCallbacks() {
  std::lock_guard<std::mutex> lock(gMutex);
  gCallbacksStopped = false;
}

}  // namespace rni::image
