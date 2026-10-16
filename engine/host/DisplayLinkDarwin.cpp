// FP-27: see DisplayLinkDarwin.h.
#include "host/DisplayLinkDarwin.h"

#include <CoreVideo/CoreVideo.h>
#include <mach/mach_time.h>

#include <chrono>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"  // CVDisplayLink: what Flutter uses

namespace rni {
namespace {

int64_t SteadyNowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

int64_t HostTicksToSteadyUs(uint64_t hostTime) {
  const double freq = CVGetHostClockFrequency();
  const double aheadUs = ((double)hostTime - (double)mach_absolute_time()) * 1e6 / freq;
  return SteadyNowUs() + (int64_t)aheadUs;
}

CVReturn OnDisplayLink(CVDisplayLinkRef, const CVTimeStamp* now, const CVTimeStamp* output,
                       CVOptionFlags, CVOptionFlags*, void* ctx) {
  const auto* sink = static_cast<const DisplayLinkDarwin::Sink*>(ctx);
  int64_t periodUs = 0;
  if (output->videoTimeScale > 0 && output->videoRefreshPeriod > 0) {
    periodUs = (int64_t)(output->videoRefreshPeriod * 1000000 / output->videoTimeScale);
  }
  (*sink)(HostTicksToSteadyUs(now->hostTime), HostTicksToSteadyUs(output->hostTime), periodUs);
  return kCVReturnSuccess;
}

}  // namespace

int64_t DisplayLinkDarwin::HostSecondsToSteadyUs(double hostSeconds) {
  return HostTicksToSteadyUs((uint64_t)(hostSeconds * CVGetHostClockFrequency()));
}

DisplayLinkDarwin::DisplayLinkDarwin(uint32_t displayId, Sink sink) : sink_(std::move(sink)) {
  CVDisplayLinkRef link = nullptr;
  const CVReturn rc = displayId ? CVDisplayLinkCreateWithCGDisplay(displayId, &link)
                                : CVDisplayLinkCreateWithActiveCGDisplays(&link);
  if (rc != kCVReturnSuccess || !link) return;
  CVDisplayLinkSetOutputCallback(link, &OnDisplayLink, &sink_);
  if (CVDisplayLinkStart(link) != kCVReturnSuccess) {
    CVDisplayLinkRelease(link);
    return;
  }
  link_ = link;
}

DisplayLinkDarwin::~DisplayLinkDarwin() {
  if (!link_) return;
  auto link = static_cast<CVDisplayLinkRef>(link_);
  CVDisplayLinkStop(link);  // waits for an in-flight callback
  CVDisplayLinkRelease(link);
}

int64_t DisplayLinkDarwin::nominalPeriodUs() const {
  if (!link_) return 0;
  const CVTime t = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(static_cast<CVDisplayLinkRef>(link_));
  if (t.flags & kCVTimeIsIndefinite || t.timeScale <= 0) return 0;
  return (int64_t)(t.timeValue * 1000000 / t.timeScale);
}

}  // namespace rni
