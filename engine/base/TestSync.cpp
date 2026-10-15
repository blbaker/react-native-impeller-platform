#include "base/TestSync.h"

#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <thread>

namespace rni::testsync {
namespace {
volatile std::sig_atomic_t gQuitSignal = 0;

void OnQuitSignal(int sig) { gQuitSignal = sig; }

double ReadScale() {
  const char* v = std::getenv("RNI_TIME_SCALE");
  if (!v || !*v) return 1.0;
  const double s = std::atof(v);
  if (s < 1.0) return 1.0;
  return s > 50.0 ? 50.0 : s;
}

int ReadFrameDelay() {
  const char* v = std::getenv("RNI_TEST_FRAME_DELAY_MS");
  if (!v || !*v) return 0;
  const int ms = std::atoi(v);
  if (ms <= 0) return 0;
  return ms > 1000 ? 1000 : ms;
}
}  // namespace

double TimeScale() {
  static const double scale = ReadScale();
  return scale;
}

int ScaledMs(int ms) { return static_cast<int>(ms * TimeScale()); }

void InstallQuitSignals() {
  std::signal(SIGTERM, OnQuitSignal);
  std::signal(SIGINT, OnQuitSignal);
}

bool QuitRequested() { return gQuitSignal != 0; }

int QuitSignal() { return static_cast<int>(gQuitSignal); }

int FrameDelayMs() {
  static const int ms = ReadFrameDelay();
  return ms;
}

void DelayFrame() {
  const int ms = FrameDelayMs();
  if (ms > 0) std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

}  // namespace rni::testsync
