// FP-54: frame timings and host spans in the React Native DevTools
// Performance panel. The same hook RN's own hosts use
// (RCTHost.mm RCTHostTracingDelegate + RCTFrameTimingsObserver,
// JReactHostInspectorTarget TracingDelegate): HostTarget calls
// onTracingStarted/onTracingStopped around a recording, and the host reports
// each frame with HostTarget::recordFrameTimings in between.
//
// Frames come from our FrameTimingsRecorder (base/DevToolsFrames.h), spans
// from TRACE_EVENT (base/Trace.h, reported as console.timeStamp-style
// TimeStamp events on one custom track per thread). Both are off, and cost
// one relaxed atomic load, whenever no trace records.
#pragma once

#include <jsinspector-modern/HostTarget.h>

#include <memory>

namespace rni {

class DevToolsTracing final
    : public facebook::react::jsinspector_modern::HostTargetTracingDelegate {
 public:
  void setHostTarget(
      std::weak_ptr<facebook::react::jsinspector_modern::HostTarget> target) {
    target_ = std::move(target);
  }

  // Called by HostTarget on the inspector queue, under its tracing mutex.
  void onTracingStarted(facebook::react::jsinspector_modern::tracing::Mode mode,
                        bool screenshotsCategoryEnabled) override;
  void onTracingStopped() override;

  // InspectorHost::shutdown: a recording the session never ended.
  void detach();

 private:
  std::weak_ptr<facebook::react::jsinspector_modern::HostTarget> target_;
};

}  // namespace rni
