#include "EllipsizeText.h"

#include <string>

namespace rni {
namespace {
const char* const kEllipsis = "\xE2\x80\xA6";

// Byte offsets where a user-visible character starts: a UTF-8 lead byte that is
// not a combining mark (U+0300..U+036F) or joined by a zero-width joiner.
std::vector<size_t> CharStarts(const std::string& s) {
  std::vector<size_t> out;
  for (size_t i = 0; i < s.size(); ++i) {
    const unsigned char b = (unsigned char)s[i];
    if ((b & 0xC0) == 0x80) continue;
    const bool combining = b == 0xCC || (b == 0xCD && i + 1 < s.size() && (unsigned char)s[i + 1] <= 0xAF);
    const bool joined = i >= 3 && s.compare(i - 3, 3, "\xE2\x80\x8D") == 0;
    if (!out.empty() && (combining || joined)) continue;
    out.push_back(i);
  }
  return out;
}

struct Cut {
  size_t run;
  size_t byte;
};

// Keep `head` characters from the start and `tail` from the end of the joined text.
std::vector<TextRun> Build(const std::vector<TextRun>& runs, const std::vector<Cut>& starts, size_t head,
                           size_t tail) {
  std::vector<TextRun> out = runs;
  const size_t total = starts.size();
  const Cut dropFrom = head < total ? starts[head] : Cut{runs.size(), 0};
  const Cut dropTo = tail > 0 ? starts[total - tail] : Cut{runs.size(), 0};
  bool placed = false;
  for (size_t r = 0; r < runs.size(); ++r) {
    const std::string& t = runs[r].text;
    size_t from = r == dropFrom.run ? dropFrom.byte : (r < dropFrom.run ? t.size() : 0);
    size_t to = r == dropTo.run ? dropTo.byte : (r < dropTo.run ? t.size() : 0);
    if (r > dropTo.run) to = 0;
    std::string kept;
    if (r < dropFrom.run || (r == dropFrom.run && from > 0)) kept = t.substr(0, from);
    if (!placed && (r > dropFrom.run || r == dropFrom.run)) {
      kept += kEllipsis;
      placed = true;
    }
    if (r > dropTo.run) kept += t;
    else if (r == dropTo.run) kept += t.substr(to);
    out[r].text = kept;
  }
  if (!placed && !out.empty()) out.back().text += kEllipsis;
  return out;
}
}  // namespace

std::vector<TextRun> EllipsizeRuns(const std::vector<TextRun>& runs, int mode, float w,
                                   const std::function<float(const std::vector<TextRun>&)>& widthOf) {
  if (w <= 0 || widthOf(runs) <= w) return runs;
  std::vector<Cut> starts;
  for (size_t r = 0; r < runs.size(); ++r)
    for (size_t b : CharStarts(runs[r].text)) starts.push_back({r, b});
  const size_t total = starts.size();
  auto make = [&](size_t keep) {
    const size_t head = mode == 1 ? 0 : (keep + 1) / 2;
    return Build(runs, starts, head, keep - head);
  };
  size_t lo = 0, hi = total;  // largest `keep` whose text fits; keep 0 is just the ellipsis
  while (lo < hi) {
    const size_t mid = (lo + hi + 1) / 2;
    if (widthOf(make(mid)) <= w) lo = mid;
    else hi = mid - 1;
  }
  return make(lo);
}

}  // namespace rni
