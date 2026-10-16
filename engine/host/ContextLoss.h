// FP-32: GPU context loss -> teardown + rebuild (windowed GL/EGL).
//
// Flutter at our pin has no EGL_CONTEXT_LOST handling of its own (grep finds
// only error-string tables); its recovery shape is the platform-view cycle:
// shell.cc OnPlatformViewDestroyed -> Rasterizer::Teardown on the raster
// thread, then the IO manager drains, then OnPlatformViewCreated ->
// Rasterizer::Setup + a new resource context + Engine::ScheduleFrame. This
// module is the state between those halves:
//   raster thread  Report() when a swap returns EGL_CONTEXT_LOST, the KHR
//                  robustness reset status is not NO_ERROR, or the test hook
//                  fires; every queued frame is then dropped (no GL on a dead
//                  context) until main has rebuilt everything
//   main thread    Lost() -> RecoverContext (ContextRecovery.h) -> Recovered()
// Test hook RNI_TEST_CONTEXT_LOSS_AT_FRAME=N[,N...]: N is a PRESENT number
// (frame numbers are not in submit order); the loss is declared right after
// that present. RNI_TEST_CONTEXT_LOSS_PROBE=<dir> writes the frame presented
// at the first N (ref.ppm) and the first 3 presents after each recovery
// (loss<k>-<j>.ppm) for tools/ci-context-loss.sh.
#pragma once

#include <cstdint>
#include <functional>
#include <vector>

#include "host/Pixel.h"

namespace rni::ctxloss {

// Raster thread. True when the test hook asks for a loss after present n.
bool ForceAtPresent(int n);
// Raster thread. The first report wins until Recovered(); later ones are counted.
void Report(const char* reason, int present, uint64_t frame);
bool Lost();
void NoteDropped();  // a queued frame was dropped while lost
// Main: called after a Report (any thread), e.g. FrameScheduler::RequestFrame.
void SetWake(std::function<void()> fn);
// Main, after the rebuild. ok=false leaves the loss pending (retried next frame).
void Recovered(bool ok, int64_t rebuildUs, const char* detail);
// Main: the first frame after a recovery must not be a damage clip.
bool ConsumeFullRepaint();
// Raster thread, before present n: probe captures + the first-present line.
bool WantsCapture(int n);
void OnPresent(const std::vector<Px>& px, int w, int h, int n);
void NotePresent(int n);
void PrintSummary();

}  // namespace rni::ctxloss
