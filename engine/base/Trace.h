// Trace spans -> Chrome trace-event JSON (loadable in ui.perfetto.dev).
// Model: flutter/fml/trace_event.h (TRACE_EVENT0/1, TRACE_COUNTER) at our SDK
// pin. Flutter forwards to the Dart timeline / Perfetto; we buffer in memory
// and write one JSON file at exit (--trace-out). When tracing is off a span
// costs one relaxed atomic load.
#pragma once

#include <atomic>
#include <cstdint>
#include <string>

namespace rni::trace {

extern std::atomic<bool> gEnabled;

inline bool Enabled() { return gEnabled.load(std::memory_order_relaxed); }

// Start recording; Stop() writes `path` and disables. Start returns false
// when already started.
bool Start(const std::string& path);
bool Stop();
// Events recorded so far (0 whenever tracing was never enabled).
uint64_t EventCount();
// Names the calling thread in the trace (and the OS thread name on Linux).
// Cheap; safe to call with tracing off so the name is known if it turns on.
void SetThreadName(const char* name);

void Begin(const char* category, const char* name, const char* argKey = nullptr,
           int64_t argValue = 0);
void End();
void Counter(const char* name, int64_t value);

class Scope {
 public:
  Scope(const char* category, const char* name, const char* argKey = nullptr,
        int64_t argValue = 0)
      : on_(Enabled()) {
    if (on_) Begin(category, name, argKey, argValue);
  }
  ~Scope() {
    if (on_) End();
  }
  Scope(const Scope&) = delete;
  Scope& operator=(const Scope&) = delete;

 private:
  const bool on_;
};

}  // namespace rni::trace

#define RNI_TRACE_CAT_(a, b) a##b
#define RNI_TRACE_VAR_(line) RNI_TRACE_CAT_(rniTraceScope_, line)
#define TRACE_EVENT0(category, name) \
  ::rni::trace::Scope RNI_TRACE_VAR_(__LINE__)(category, name)
#define TRACE_EVENT1(category, name, key, value) \
  ::rni::trace::Scope RNI_TRACE_VAR_(__LINE__)(category, name, key, (int64_t)(value))
#define TRACE_COUNTER(name, value)                                  \
  do {                                                              \
    if (::rni::trace::Enabled()) ::rni::trace::Counter(name, value); \
  } while (0)
