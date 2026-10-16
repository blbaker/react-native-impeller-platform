#pragma once
// FP-50: a text record of every Impeller builder call the painter makes (op, args,
// transform, clip), taken per thread while a Capture is installed. It is the draw-op
// layer Flutter's TEST_P suites assert on (impeller/display_list/dl_dispatcher_unittests.cc
// and aiks_unittests.cc compare recorded ops, not pixels). The hooks are in
// DrawOpHooks.cpp; DrawOpHook.h redirects the painter's calls to them.
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace rni::drawop {

struct Op {
  int builder{0};
  int depth{0};
  std::string text;
  std::string state;  // "ctm=... clip=..." on draw and clip ops
};

struct Box {
  bool bounded{false};
  float l{0}, t{0}, r{0}, b{0};
};
struct BuilderState {
  int id{0};
  int depth{0};
  std::vector<Box> clips{Box{}};  // top = current device-space clip bounds
};
struct PaintState {
  std::string color{"#000000ff"};
  std::string stroke, blend, colorFilter, colorSource, imageFilter, maskFilter;
  int style{0}, cap{0}, join{0};  // ImpellerDrawStyle / StrokeCap / StrokeJoin
  float width{0}, miter{4};
  std::string Str() const;
};
struct PathState {
  std::string cmds;
  Box bounds;
};
struct StyleState {
  float size{0};
  std::string family;
  int weight{0};
};
struct ParaBuilderState {
  StyleState cur;
  std::string runs;
};

class Capture {
 public:
  std::vector<Op> ops;
  std::unordered_map<const void*, BuilderState> builders;
  std::unordered_map<const void*, PaintState> paints;
  std::unordered_map<const void*, std::string> objects;  // sources, filters, paragraphs
  std::unordered_map<const void*, PathState> pathBuilders, paths;
  std::unordered_map<const void*, StyleState> styles;
  std::unordered_map<const void*, ParaBuilderState> paraBuilders;
  int nextBuilder{0};

  // One op per line, indented by save depth, "b<N>:" before ops of a nested builder.
  std::string Format(bool withState) const;
};

class ScopedCapture {
 public:
  explicit ScopedCapture(Capture& c);
  ~ScopedCapture();
  ScopedCapture(const ScopedCapture&) = delete;
  ScopedCapture& operator=(const ScopedCapture&) = delete;

 private:
  Capture* prev_;
};

Capture* Current();  // this thread's capture, or null

// --dump-draw-ops <file>: RecordFrame appends one "frame N" section per painted frame.
void SetDumpPath(const std::string& path);
bool DumpEnabled();
void AppendFrame(uint64_t frame, const Capture& capture);

}  // namespace rni::drawop
