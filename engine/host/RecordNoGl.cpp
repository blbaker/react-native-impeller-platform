// FP-14: see RecordNoGl.h.
#include "host/RecordNoGl.h"

#include "scenegraph/RasterJobs.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>

#if !defined(_WIN32)
#include <dlfcn.h>
#endif

namespace rni::recordgl {

namespace {

std::mutex gHooksMutex;
ContextHooks gHooks;
std::atomic<uint64_t> gRecordCalls{0}, gRasterCalls{0}, gFrames{0}, gReleased{0};
std::atomic<uint64_t> gStarved{0};

using CountFn = unsigned long (*)();
CountFn ShimCounter() {
#if defined(_WIN32)
  return nullptr;
#else
  static CountFn fn =
      reinterpret_cast<CountFn>(dlsym(RTLD_DEFAULT, "rni_gl_shim_thread_calls"));
  return fn;
#endif
}

uint64_t ThreadCalls() {
  CountFn fn = ShimCounter();
  return fn ? (uint64_t)fn() : 0;
}

ContextHooks Hooks() {
  std::lock_guard<std::mutex> lock(gHooksMutex);
  return gHooks;
}

}  // namespace

void SetContextHooks(ContextHooks hooks) {
  std::lock_guard<std::mutex> lock(gHooksMutex);
  gHooks = std::move(hooks);
}

bool AssertMode() {
  static const bool on = [] {
    const char* v = std::getenv("RNI_ASSERT_NO_GL_IN_RECORD");
    return v != nullptr && std::strcmp(v, "1") == 0;
  }();
  return on;
}

RecordScope::RecordScope() {
  if (AssertMode()) {
    ContextHooks h = Hooks();
    if (h.release && h.isCurrent) {
      released_ = h.release();
      if (h.isCurrent()) {
        std::fprintf(stderr, "rn-impeller: record_gl ASSERT: a GL context is current in RECORD\n");
        std::fflush(stderr);
        std::abort();
      }
      if (released_) gReleased.fetch_add(1, std::memory_order_relaxed);
    }
  }
  start_ = ThreadCalls();
}

RecordScope::~RecordScope() {
  gRecordCalls.fetch_add(ThreadCalls() - start_, std::memory_order_relaxed);
  gFrames.fetch_add(1, std::memory_order_relaxed);
  if (released_) {
    ContextHooks h = Hooks();
    if (!h.acquire || !h.acquire()) {
      std::fprintf(stderr, "rn-impeller: record_gl could not make the context current again\n");
      std::fflush(stderr);
      std::abort();
    }
  }
}

RasterScope::RasterScope() : start_(ThreadCalls()) {}
RasterScope::~RasterScope() {
  gRasterCalls.fetch_add(ThreadCalls() - start_, std::memory_order_relaxed);
}

void NoteStarved(uint64_t starved) { gStarved.store(starved, std::memory_order_relaxed); }

void PrintSummary() {
  const RasterJobs::Totals jobs = RasterJobs::totals();
  std::printf("rn-impeller: record_gl calls=%llu raster_calls=%llu frames=%llu shim=%d "
              "assert=%d released=%llu starved=%llu uploads=%llu offscreens=%llu "
              "jobs_failed=%llu\n",
              (unsigned long long)gRecordCalls.load(), (unsigned long long)gRasterCalls.load(),
              (unsigned long long)gFrames.load(), ShimCounter() != nullptr ? 1 : 0,
              AssertMode() ? 1 : 0, (unsigned long long)gReleased.load(),
              (unsigned long long)gStarved.load(), (unsigned long long)jobs.uploads,
              (unsigned long long)jobs.offscreens, (unsigned long long)jobs.failed);
  std::fflush(stdout);
}

}  // namespace rni::recordgl
