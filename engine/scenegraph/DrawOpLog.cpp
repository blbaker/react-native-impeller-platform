// FP-50: Capture formatting and the --dump-draw-ops file. See DrawOpLog.h.
#include "scenegraph/DrawOpLog.h"

#include <cstdio>
#include <mutex>

namespace rni::drawop {

namespace {
thread_local Capture* tCurrent = nullptr;
std::mutex gDumpMutex;
std::string gDumpPath;
bool gDumpStarted = false;
}  // namespace

std::string PaintState::Str() const {
  std::string s = "paint(" + color;
  for (const std::string* part :
       {&stroke, &blend, &colorFilter, &colorSource, &imageFilter, &maskFilter}) {
    if (!part->empty()) s += " " + *part;
  }
  return s + ")";
}

std::string Capture::Format(bool withState) const {
  std::string out;
  for (const Op& op : ops) {
    out.append((size_t)op.depth * 2, ' ');
    if (op.builder != 0) out += "b" + std::to_string(op.builder) + ": ";
    out += op.text;
    if (withState && !op.state.empty()) out += " | " + op.state;
    out += "\n";
  }
  return out;
}

ScopedCapture::ScopedCapture(Capture& c) : prev_(tCurrent) { tCurrent = &c; }
ScopedCapture::~ScopedCapture() { tCurrent = prev_; }
Capture* Current() { return tCurrent; }

void SetDumpPath(const std::string& path) {
  std::lock_guard<std::mutex> lock(gDumpMutex);
  gDumpPath = path;
}

bool DumpEnabled() {
  std::lock_guard<std::mutex> lock(gDumpMutex);
  return !gDumpPath.empty();
}

void AppendFrame(uint64_t frame, const Capture& capture) {
  std::lock_guard<std::mutex> lock(gDumpMutex);
  if (gDumpPath.empty()) return;
  FILE* f = std::fopen(gDumpPath.c_str(), gDumpStarted ? "a" : "w");
  if (!f) {
    std::fprintf(stderr, "rn-impeller: cannot write --dump-draw-ops %s\n", gDumpPath.c_str());
    return;
  }
  gDumpStarted = true;
  std::fprintf(f, "frame %llu ops=%zu\n%s", (unsigned long long)frame, capture.ops.size(),
               capture.Format(true).c_str());
  std::fclose(f);
}

}  // namespace rni::drawop
