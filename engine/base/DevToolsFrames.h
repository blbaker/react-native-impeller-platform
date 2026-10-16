// FP-54: frame records -> React Native DevTools, only while a trace records.
// Model: flutter/shell/common/shell.cc Shell::OnFrameRasterized at our SDK pin:
// a rasterized FrameTiming leaves the engine only when someone asked for it
// (needs_report_timings_, set by SetNeedsReportTimings), and its stamps stay
// on the engine's own monotonic clock (ToEpochDelta) so the tool can line
// them up with the rest of the timeline. Here the listener is RN's
// jsinspector-modern HostTarget (runtime/DevToolsTracing.cpp installs the
// sink on HostTargetTracingDelegate::onTracingStarted and removes it on
// onTracingStopped); this file has no RN dependency.
#pragma once

#include <chrono>
#include <cstdint>
#include <functional>

namespace rni::devtools {

using Clock = std::chrono::steady_clock;

struct FrameRecord {
  uint64_t frameNumber;
  Clock::time_point begin;  // vsync stamp (Flutter FrameTiming kVsyncStart)
  Clock::time_point end;    // present stamp
};

// Called on the committing thread; must not block on the sink owner.
using FrameSink = std::function<void(const FrameRecord&)>;

struct Stats {
  uint64_t commits;   // every committed frame, recording or not
  uint64_t emitted;   // frames handed to a sink
  uint64_t sessions;  // StartRecording calls
};

// Installs the sink; frames committed from now on are emitted. Returns the
// stats at the switch so the caller can log the window's starting point.
Stats StartRecording(FrameSink sink);
// Removes the sink; nothing is emitted after this returns.
Stats StopRecording();
bool Recording();
// FrameTimings::Commit, once per presented frame.
void OnFrameCommitted(const FrameRecord& frame);
Stats GetStats();

}  // namespace rni::devtools
