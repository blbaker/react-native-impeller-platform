#pragma once
// Per-node paragraph layout cache.
//
// Before this cache, every painted frame rebuilt every visible <Text>'s
// ImpellerParagraph from scratch: style push, font fallback split, HarfBuzz
// shaping and line breaking. A frame that changed nothing but one dot's
// opacity re-shaped a whole chat transcript (Jim v5, 2026-10-19: 360 of 647
// main-thread paint samples were buildRunParagraph, the process sat at ~100%
// CPU for the length of a chat turn, and the JS thread waited on the scene
// lock that the re-shaping paint held).
//
// An entry keeps the paragraph plus a copy of EVERYTHING that shaped it, and a
// lookup compares the copy against the node by value. Nothing has to remember
// to invalidate it: a changed run, style, width, alpha, typography context or
// font set is simply a miss. Opacity or transform changes on OTHER nodes never
// touch a text node's inputs, so they hit.
#include <cstddef>
#include <cstdint>
#include <functional>
#include <mutex>
#include <unordered_map>
#include <vector>

#include "impeller.h"
#include "scenegraph/SceneGraph.h"

namespace rni {

class ParagraphCache {
 public:
  ParagraphCache() = default;
  ~ParagraphCache();
  ParagraphCache(const ParagraphCache&) = delete;
  ParagraphCache& operator=(const ParagraphCache&) = delete;

  // A +1 paragraph for `node` laid out at width `w` with text alpha `alpha`
  // (shadow -1 = the glyphs, >= 0 = that run's shadow silhouette). On a miss,
  // `build` makes it and the cache keeps its own reference. The caller
  // releases the returned paragraph as if it had built it. `build` may return
  // null; null is never cached.
  ImpellerParagraph Get(const SceneNode& node, float w, int shadow, float alpha,
                        ImpellerTypographyContext ctx, uint64_t fontEpoch,
                        const std::function<ImpellerParagraph()>& build);

  // A deleted node's entries. A reused tag would still be compared by value,
  // so this is about memory only.
  void Erase(facebook::react::Tag tag);
  void Clear();

  // RNI_PARAGRAPH_CACHE=0 turns the cache off (every Get builds). The gates'
  // control arm, and an escape hatch.
  static bool Enabled();

  size_t hits() const { return hits_; }
  size_t misses() const { return misses_; }
  size_t live() const;
  void PrintSummary() const;

 private:
  struct Entry {
    int shadow{-1};
    ImpellerParagraph paragraph{nullptr};
    // The shaping inputs, compared by value on every lookup.
    std::vector<TextRun> runs;
    int textAlign{0}, writingDirection{0}, maxLines{0}, ellipsizeMode{0};
    bool adjustsFit{false};
    float minFontScale{0.0f};
    float width{0.0f};
    float alpha{1.0f};
    ImpellerTypographyContext ctx{nullptr};
    uint64_t fontEpoch{0};
  };
  static bool Matches(const Entry& e, const SceneNode& node, float w, float alpha,
                      ImpellerTypographyContext ctx, uint64_t fontEpoch);
  static void Release(Entry& e);
  void ClearLocked();

  mutable std::mutex mu_;
  // Per tag: one entry for the glyphs, plus one per distinct text shadow.
  std::unordered_map<facebook::react::Tag, std::vector<Entry>> entries_;
  uint64_t epoch_{0};
  size_t hits_{0}, misses_{0};
};

}  // namespace rni
