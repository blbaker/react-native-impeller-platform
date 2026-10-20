// See ParagraphCache.h.
#include "scenegraph/ParagraphCache.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "scenegraph/DrawOpLog.h"

namespace rni {

ParagraphCache::~ParagraphCache() { Clear(); }

bool ParagraphCache::Enabled() {
  static const bool on = [] {
    const char* v = std::getenv("RNI_PARAGRAPH_CACHE");
    return v == nullptr || std::strcmp(v, "0") != 0;
  }();
  return on;
}

namespace {
// RN leaves unset floats NaN (ParagraphAttributes::minimumFontScale is NaN on
// every <Text> without adjustsFontSizeToFit), and NaN != NaN: a plain == made
// every lookup miss. Two NaNs are the same input.
bool Same(float a, float b) { return a == b || (std::isnan(a) && std::isnan(b)); }
}  // namespace

bool ParagraphCache::Matches(const Entry& e, const SceneNode& node, float w, float alpha,
                             ImpellerTypographyContext ctx, uint64_t fontEpoch) {
  // Every input buildRunParagraph reads. TextRun compares member-wise
  // (defaulted operator==), so a field added to TextRun is compared too; its
  // floats are NaN-free (updateFromShadowView keeps the defaults for unset
  // values), and a NaN slipping in would only cost a miss, which
  // ci-paragraph-cache arm A counts.
  return e.ctx == ctx && e.fontEpoch == fontEpoch && Same(e.width, w) && Same(e.alpha, alpha) &&
         e.textAlign == node.textAlign && e.writingDirection == node.writingDirection &&
         e.maxLines == node.maxLines && e.ellipsizeMode == node.ellipsizeMode &&
         e.adjustsFit == node.adjustsFit && Same(e.minFontScale, node.minFontScale) &&
         e.runs == node.runs;
}

void ParagraphCache::Release(Entry& e) {
  if (e.paragraph != nullptr) ImpellerParagraphRelease(e.paragraph);
  e.paragraph = nullptr;
}

ImpellerParagraph ParagraphCache::Get(const SceneNode& node, float w, int shadow, float alpha,
                                      ImpellerTypographyContext ctx, uint64_t fontEpoch,
                                      const std::function<ImpellerParagraph()>& build) {
  // --dump-draw-ops describes a paragraph when it is BUILT, per frame capture;
  // a cached one would print as text(?). Capturing frames shape fresh.
  if (!Enabled() || drawop::Current() != nullptr) {
    std::lock_guard<std::mutex> lock(mu_);
    ++misses_;
    return build();
  }
  std::lock_guard<std::mutex> lock(mu_);
  if (fontEpoch != epoch_) {
    // A font was added or the contexts were rebuilt: nothing shaped before
    // can be trusted, and old paragraphs pin the old context's fonts.
    ClearLocked();
    epoch_ = fontEpoch;
  }
  std::vector<Entry>& list = entries_[node.tag];
  Entry* slot = nullptr;
  for (Entry& e : list) {
    if (e.shadow == shadow) slot = &e;
  }
  if (slot != nullptr && slot->paragraph != nullptr &&
      Matches(*slot, node, w, alpha, ctx, fontEpoch)) {
    ++hits_;
    ImpellerParagraphRetain(slot->paragraph);
    return slot->paragraph;
  }
  ++misses_;
  ImpellerParagraph p = build();
  if (slot == nullptr) {
    list.emplace_back();
    slot = &list.back();
    slot->shadow = shadow;
  }
  Release(*slot);
  if (p == nullptr) return nullptr;
  ImpellerParagraphRetain(p);
  slot->paragraph = p;
  slot->runs = node.runs;
  slot->textAlign = node.textAlign;
  slot->writingDirection = node.writingDirection;
  slot->maxLines = node.maxLines;
  slot->ellipsizeMode = node.ellipsizeMode;
  slot->adjustsFit = node.adjustsFit;
  slot->minFontScale = node.minFontScale;
  slot->width = w;
  slot->alpha = alpha;
  slot->ctx = ctx;
  slot->fontEpoch = fontEpoch;
  return p;
}

void ParagraphCache::Erase(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mu_);
  auto it = entries_.find(tag);
  if (it == entries_.end()) return;
  for (Entry& e : it->second) Release(e);
  entries_.erase(it);
}

void ParagraphCache::ClearLocked() {
  for (auto& [tag, list] : entries_) {
    for (Entry& e : list) Release(e);
  }
  entries_.clear();
}

void ParagraphCache::Clear() {
  std::lock_guard<std::mutex> lock(mu_);
  ClearLocked();
}

size_t ParagraphCache::live() const {
  std::lock_guard<std::mutex> lock(mu_);
  size_t n = 0;
  for (const auto& [tag, list] : entries_) {
    for (const Entry& e : list) n += e.paragraph != nullptr ? 1 : 0;
  }
  return n;
}

void ParagraphCache::PrintSummary() const {
  const size_t n = live();
  std::lock_guard<std::mutex> lock(mu_);
  std::printf("rn-impeller: paragraph_cache enabled=%d hits=%zu misses=%zu live=%zu\n",
              Enabled() ? 1 : 0, hits_, misses_, n);
  std::fflush(stdout);
}

}  // namespace rni
