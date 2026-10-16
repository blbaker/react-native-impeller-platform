// FP-54 -- see DevToolsTracing.h. Model: flutter/shell/common/shell.cc
// Shell::OnFrameRasterized (timings leave the engine only while a listener
// asked) and packages/flutter/lib/src/scheduler/binding.dart
// _profileFramePostEvent (one DevTools frame event per FrameTiming).
#include "runtime/DevToolsTracing.h"

#include <jsinspector-modern/tracing/FrameTimingSequence.h>
#include <jsinspector-modern/tracing/PerformanceTracer.h>
#include <oscompat/OSCompat.h>
#include <react/timing/primitives.h>

#include <cstdio>
#include <string>

#include "base/DevToolsFrames.h"
#include "base/Trace.h"

namespace rni {

namespace jsi_m = facebook::react::jsinspector_modern;
using facebook::react::HighResTimeStamp;

namespace {

void ReportSpan(const char* /*category*/, const char* name, const char* threadName,
                std::chrono::steady_clock::time_point begin,
                std::chrono::steady_clock::time_point end) {
  jsi_m::tracing::PerformanceTracer::getInstance().reportTimeStamp(
      name, HighResTimeStamp::fromChronoSteadyClockTimePoint(begin),
      HighResTimeStamp::fromChronoSteadyClockTimePoint(end),
      std::string("rn-impeller ") + threadName, std::string("rn-impeller host"));
}

void Log(const char* what, const devtools::Stats& s) {
  std::printf("rn-impeller: devtools_trace %s commits=%llu emitted=%llu sessions=%llu\n",
              what, (unsigned long long)s.commits, (unsigned long long)s.emitted,
              (unsigned long long)s.sessions);
  std::fflush(stdout);
}

}  // namespace

void DevToolsTracing::onTracingStarted(jsi_m::tracing::Mode /*mode*/,
                                       bool /*screenshotsCategoryEnabled*/) {
  std::weak_ptr<jsi_m::HostTarget> weak = target_;
  const devtools::Stats s = devtools::StartRecording(
      [weak](const devtools::FrameRecord& f) {
        auto target = weak.lock();
        if (!target) return;
        // Same clock as every RN trace event: HighResTimeStamp wraps
        // steady_clock, and the recorder stamps steady_clock.
        target->recordFrameTimings(jsi_m::tracing::FrameTimingSequence(
            f.frameNumber, facebook::react::oscompat::getCurrentThreadId(),
            HighResTimeStamp::fromChronoSteadyClockTimePoint(f.begin),
            HighResTimeStamp::fromChronoSteadyClockTimePoint(f.end)));
      });
  trace::SetSpanSink(&ReportSpan);
  Log("started", s);
}

void DevToolsTracing::onTracingStopped() {
  trace::SetSpanSink(nullptr);
  Log("stopped", devtools::StopRecording());
}

void DevToolsTracing::detach() {
  if (!devtools::Recording()) return;
  trace::SetSpanSink(nullptr);
  devtools::StopRecording();
}

}  // namespace rni
