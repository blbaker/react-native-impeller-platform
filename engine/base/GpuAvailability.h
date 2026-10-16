// FP-31: the one GPU-availability switch.
//
// Model: flutter/shell/common/shell.cc Shell::SetGpuAvailability (sets
// is_gpu_disabled_sync_switch_) driven by FlutterEngine.mm
// flutterDidEnterBackground -> setIsGpuDisabled:YES, and fml::SyncSwitch
// (the flip waits for GPU work already inside the switch). Checked by
// Rasterizer::DrawToSurfaces (kGpuUnavailable: no draw, no present) and by
// ShellIOManager / Rasterizer::MakeGpuImage (no GPU upload or snapshot).
//
// Here: GPU work (a raster draw + present, an IO-thread texture upload, a
// readback) runs inside a Section, which holds the switch shared. Set() takes
// it exclusive, so once Set(false) returns no GPU call is running and none
// starts until Set(true). RECORD (main) only reads Available() to skip a
// frame; JS, layout and mount are never paused.
#pragma once

#include <cstdint>
#include <functional>
#include <shared_mutex>

namespace rni::gpu {

class Section {
 public:
  Section();
  Section(const Section&) = delete;
  Section& operator=(const Section&) = delete;
  // False when the GPU is unavailable: the caller must not touch it.
  bool available() const { return available_; }

 private:
  std::shared_lock<std::shared_mutex> lock_;
  bool available_;
};

// Lock-free read for the main thread's RECORD gate.
bool Available();

// Any thread except from inside a Section. Waits for sections in flight, then
// flips, prints `gpu_availability state= reason= ... counters`, and on a
// restore marks a full repaint and runs the restore listener.
void Set(bool available, const char* reason);
void SetRestoreListener(std::function<void()> fn);
// RECORD: true once after a restore (paint everything, no damage clip).
bool ConsumeRestore();

enum class Counter { kRecord, kDraw, kPresent, kUpload, kSnapshot, kSkippedFrame, kSkippedUpload };
// Bumped at the call sites that really did the work (or skipped it).
void Note(Counter c);
// Raster thread, first present after a restore (prints gpu_restore_present).
void NotePresent(int presentNumber, bool fullRepaint);
int64_t LastRestoreUs();

// `gpu_availability_summary ...` at exit.
void PrintSummary();

}  // namespace rni::gpu
