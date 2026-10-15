// FP-52: the RNSVG geometry parsers. Model: Skia fuzz/oss_fuzz/FuzzParsePath.cpp
// (parse, then use the result) and fuzz/FuzzPathMeasure.cpp (dash/measure).
#include <fuzzer/FuzzedDataProvider.h>

#include <cstdlib>
#include <string>
#include <string_view>
#include <vector>

#include "fuzz/Fuzz.h"
#include "impeller.h"
#include "svg/SvgDash.h"
#include "svg/SvgPath.h"

namespace rni::fuzz {

namespace {

class CountingSink final : public SvgPathSink {
 public:
  void moveTo(float, float) override { ++calls; }
  void lineTo(float, float) override { ++calls; }
  void quadTo(float, float, float, float) override { ++calls; }
  void cubicTo(float, float, float, float, float, float) override { ++calls; }
  void close() override { ++calls; }
  long calls = 0;
};

// The painter's use of a parsed path: fill and stroke it into a display list.
void RecordPath(ImpellerPath path) {
  ImpellerRect bounds{};
  ImpellerPathGetBounds(path, &bounds);
  ImpellerDisplayListBuilder dl = ImpellerDisplayListBuilderNew(nullptr);
  ImpellerPaint paint = ImpellerPaintNew();
  ImpellerDisplayListBuilderDrawPath(dl, path, paint);
  ImpellerPaintSetDrawStyle(paint, kImpellerDrawStyleStroke);
  ImpellerDisplayListBuilderDrawPath(dl, path, paint);
  ImpellerDisplayList list = ImpellerDisplayListBuilderCreateDisplayListNew(dl);
  ImpellerDisplayListRelease(list);
  ImpellerPaintRelease(paint);
  ImpellerDisplayListBuilderRelease(dl);
}

}  // namespace

int SvgPath(const uint8_t* data, size_t size) {
  if (size > 4096) return 0;  // Skia caps FuzzParsePath at 1000; icons are longer
  // The exact libFuzzer buffer, no copy: a read past the end is an ASan report.
  std::string_view d(reinterpret_cast<const char*>(data), size);
  CountingSink sink;
  const bool parsed = ParseSvgPath(d, sink);
  if (parsed && sink.calls == 0) std::abort();  // "parsed" must mean geometry

  ImpellerPathBuilder pb = ImpellerPathBuilderNew();
  if (ParseSvgPathToBuilder(std::string(d), pb) != parsed) std::abort();
  ImpellerPath path = ImpellerPathBuilderTakePathNew(pb, kImpellerFillTypeNonZero);
  ImpellerPathBuilderRelease(pb);
  if (path) RecordPath(path);
  ImpellerPathRelease(path);
  return 0;
}

int SvgDash(const uint8_t* data, size_t size) {
  if (size > 4096) return 0;
  FuzzedDataProvider in(data, size);
  const bool capDots = in.ConsumeBool();
  const float offset = in.ConsumeFloatingPoint<float>();
  std::vector<float> raw(in.ConsumeIntegralInRange<size_t>(0, 9));
  for (float& v : raw) v = in.ConsumeFloatingPoint<float>();
  const std::string d = in.ConsumeRemainingBytesAsString();

  const std::vector<float> pattern = NormaliseSvgDashArray(raw);
  if (pattern.size() % 2 != 0) std::abort();  // the contract: even or empty
  if (pattern.empty()) return 0;              // the painter strokes solid
  int dashes = -1;
  ImpellerPath path = BuildDashedSvgPath(d, pattern, offset, capDots, &dashes);
  if (path) {
    if (dashes < 0 || dashes > kMaxSvgDashes) std::abort();
    RecordPath(path);
    ImpellerPathRelease(path);
  }
  return 0;
}

}  // namespace rni::fuzz
