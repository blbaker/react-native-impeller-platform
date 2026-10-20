// Test hook for ci-idle-commit-paint: capture what is ON SCREEN, on request,
// without asking for a frame.
//
// RNI_TEST_PRESENTED_CAPTURE=<dir> makes the raster thread keep a copy of
// every windowed present (read back before the present, like the other
// present probes). A watcher thread polls <dir> for request files `req-<k>`;
// for each one it writes the LAST PRESENTED frame to `shot-<k>.ppm`, then
// creates `shot-<k>.done` and prints
//   presented_capture k= present= frame= age_ms=
// (age_ms = how long ago that frame presented).
//
// Why not --screenshot: a pending --screenshot is a test hand, and the windowed
// loop paints EVERY frame while one is pending (handsPending in main.cpp). That
// forces exactly the repaint whose absence this gate exists to catch. This hook
// never requests a frame, never wakes the loop and never touches the scene: it
// only reports what the last present put on the window. Unset: nothing is read
// back and no thread runs.
#pragma once

#include "host/Pixel.h"

#include <cstdint>
#include <vector>

namespace rni::presentedcapture {

bool Enabled();
// Raster thread, before the present. px is top-left ordered, width*height.
void OnPresent(const std::vector<Px>& px, int width, int height, int present,
               uint64_t frameNumber);
// Main thread: start / stop the request watcher (no-ops when disabled).
void Start();
void Stop();

}  // namespace rni::presentedcapture
