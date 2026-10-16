// Model: flutter/fml/trace_event.cc. Events are buffered per process under one
// mutex (only touched when tracing is on) and serialised at Stop().
#include "base/Trace.h"

#include <chrono>
#include <cstdio>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#if defined(__linux__)
#include <pthread.h>
#endif

namespace rni::trace {

std::atomic<bool> gEnabled{false};
std::atomic<bool> gSinkOn{false};

namespace {

struct Event {
  char ph;  // 'B', 'E', 'C'
  int tid;
  int64_t tsUs;
  const char* category;  // string literals only
  const char* name;
  const char* argKey;
  int64_t argValue;
};

std::mutex gMutex;
std::vector<Event> gEvents;
std::map<int, std::string> gThreadNames;
std::string gPath;
std::chrono::steady_clock::time_point gOrigin;
std::atomic<int> gNextTid{1};

int CurrentTid() {
  thread_local const int tid = gNextTid.fetch_add(1, std::memory_order_relaxed);
  return tid;
}

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now() - gOrigin)
      .count();
}

// FP-54 span sink. Every 'B' pushes and every 'E' pops (Scope pairs them
// whenever tracing of either kind was on at its start), so the stack stays
// matched even when the sink turns on or off mid-span; only spans that began
// under the CURRENT sink session are reported.
std::atomic<SpanSink> gSink{nullptr};
std::atomic<uint64_t> gSinkSession{0};
struct OpenSpan {
  const char* category;
  const char* name;
  std::chrono::steady_clock::time_point begin;
  uint64_t session;  // 0 = began with no sink
};
thread_local std::vector<OpenSpan> tOpen;
thread_local std::string tThreadName;

void ToSink(char ph, const char* cat, const char* name) {
  if (ph == 'B') {
    const uint64_t session =
        gSinkOn.load(std::memory_order_relaxed) ? gSinkSession.load() : 0;
    tOpen.push_back({cat, name, std::chrono::steady_clock::now(), session});
    return;
  }
  if (ph != 'E' || tOpen.empty()) return;
  const OpenSpan span = tOpen.back();
  tOpen.pop_back();
  const SpanSink sink = gSink.load();
  if (!sink || span.session == 0 || span.session != gSinkSession.load()) return;
  sink(span.category, span.name,
       tThreadName.empty() ? "thread" : tThreadName.c_str(), span.begin,
       std::chrono::steady_clock::now());
}

void Push(char ph, const char* cat, const char* name, const char* key, int64_t v) {
  ToSink(ph, cat, name);
  if (!gEnabled.load(std::memory_order_relaxed)) return;
  const Event e{ph, CurrentTid(), NowUs(), cat, name, key, v};
  std::lock_guard<std::mutex> lock(gMutex);
  gEvents.push_back(e);
}

void WriteEscaped(FILE* f, const char* s) {
  for (; s && *s; ++s) {
    if (*s == '"' || *s == '\\') fputc('\\', f);
    fputc(*s, f);
  }
}

}  // namespace

bool Start(const std::string& path) {
  std::lock_guard<std::mutex> lock(gMutex);
  if (gEnabled.load()) return false;
  gPath = path;
  gOrigin = std::chrono::steady_clock::now();
  gEvents.clear();
  gEnabled.store(true, std::memory_order_relaxed);
  return true;
}

uint64_t EventCount() {
  std::lock_guard<std::mutex> lock(gMutex);
  return gEvents.size();
}

void SetSpanSink(SpanSink sink) {
  if (sink) gSinkSession.fetch_add(1);
  gSink.store(sink);
  gSinkOn.store(sink != nullptr);
}

void SetThreadName(const char* name) {
  tThreadName = name;
  const int tid = CurrentTid();
  {
    std::lock_guard<std::mutex> lock(gMutex);
    gThreadNames[tid] = name;
  }
#if defined(__linux__)
  pthread_setname_np(pthread_self(), name);
#endif
}

void Begin(const char* category, const char* name, const char* argKey, int64_t argValue) {
  Push('B', category, name, argKey, argValue);
}

void End() { Push('E', "", "", nullptr, 0); }

void Counter(const char* name, int64_t value) { Push('C', "counter", name, "value", value); }

bool Stop() {
  if (!gEnabled.exchange(false)) return false;
  std::lock_guard<std::mutex> lock(gMutex);
  FILE* f = fopen(gPath.c_str(), "w");
  if (!f) return false;
  fputs("{\"displayTimeUnit\":\"ms\",\"traceEvents\":[\n", f);
  fputs("{\"ph\":\"M\",\"pid\":1,\"tid\":0,\"name\":\"process_name\",\"args\":{\"name\":\"rn-impeller\"}}", f);
  for (const auto& [tid, name] : gThreadNames) {
    fprintf(f, ",\n{\"ph\":\"M\",\"pid\":1,\"tid\":%d,\"name\":\"thread_name\",\"args\":{\"name\":\"", tid);
    WriteEscaped(f, name.c_str());
    fputs("\"}}", f);
  }
  for (const Event& e : gEvents) {
    fprintf(f, ",\n{\"ph\":\"%c\",\"pid\":1,\"tid\":%d,\"ts\":%lld", e.ph, e.tid, (long long)e.tsUs);
    if (e.ph != 'E') {
      fputs(",\"cat\":\"", f);
      WriteEscaped(f, e.category);
      fputs("\",\"name\":\"", f);
      WriteEscaped(f, e.name);
      fputc('"', f);
    }
    if (e.argKey) {
      fputs(",\"args\":{\"", f);
      WriteEscaped(f, e.argKey);
      fprintf(f, "\":%lld}", (long long)e.argValue);
    }
    fputc('}', f);
  }
  fputs("\n]}\n", f);
  const bool ok = fclose(f) == 0;
  return ok;
}

}  // namespace rni::trace
