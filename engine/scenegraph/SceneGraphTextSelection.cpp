// ENG-43: <Text selectable> selection across paragraphs.
//
// P1 item 15 kept ONE paragraph's selection. The drag mapped the cursor
// through the pressed paragraph's own layout and never looked anywhere else,
// so a drag from one paragraph into the next stopped at the first, and a drag
// below a paragraph kept the x on its last line ('Bravo fo').
//
// Here a selection is an ANCHOR (the press: textSelTag_ + textSelAnchor_) and
// a FOCUS (the drag: textSelFocusTag_ + textSelCaret_), which may sit in
// different paragraphs. Every selectable paragraph between them in document
// order is selected: paint reads each one's range from textSelRangeLocked, and
// Copy joins the parts with "\n", or with nothing between siblings of a
// flexDirection-row parent (a styled line drawn as one Text per word).
#include "scenegraph/SceneGraph.h"

#include <algorithm>
#include <cstdio>
#include <functional>
#include <limits>

namespace rni {

namespace react = facebook::react;

namespace {

using NodeMap = std::unordered_map<react::Tag, SceneNode>;

std::string JoinedRuns(const SceneNode& n) {
  std::string s;
  for (const TextRun& r : n.runs) s += r.text;
  return s;
}

bool IsSelectableText(const SceneNode& n) {
  return n.isParagraph && n.selectable && !n.runs.empty();
}

struct Box {
  float l = 0, t = 0, r = 0, b = 0;
  bool empty = true;
  void add(const Box& o) {
    if (o.empty) return;
    if (empty) {
      *this = o;
      return;
    }
    l = std::min(l, o.l);
    t = std::min(t, o.t);
    r = std::max(r, o.r);
    b = std::max(b, o.b);
  }
  void clip(float cl, float ct, float cr, float cb) {
    if (empty) return;
    l = std::max(l, cl);
    t = std::max(t, ct);
    r = std::min(r, cr);
    b = std::min(b, cb);
    if (l >= r || t >= b) empty = true;
  }
  bool contains(float x, float y) const {
    return !empty && x >= l && x < r && y >= t && y < b;
  }
};

// The origin a child of `n` (at absolute nx,ny) is laid out from: a
// ScrollView shifts its children by -scroll, exactly as paintNode and
// hitTestNode do.
void ChildOrigin(const SceneNode& n, float nx, float ny, float* cx, float* cy) {
  *cx = n.isScrollView ? nx - n.scrollX : nx;
  *cy = n.isScrollView ? ny - n.scrollY : ny;
}

// Where the selectable text in `n`'s subtree is on screen: the union of its
// selectable paragraphs' boxes, cropped by every clipping node on the way down
// (text scrolled out of a list cannot be pointed at).
Box TextBounds(const NodeMap& nodes, react::Tag scope, const SceneNode& n, float nx,
               float ny) {
  const float w = (float)n.layoutMetrics.frame.size.width;
  const float h = (float)n.layoutMetrics.frame.size.height;
  Box out;
  if (IsSelectableText(n)) {
    if (w > 0.0f && h > 0.0f) out = Box{nx, ny, nx + w, ny + h, false};
    return out;
  }
  float cx, cy;
  ChildOrigin(n, nx, ny, &cx, &cy);
  for (react::Tag c : n.children) {
    auto it = nodes.find(c);
    if (it == nodes.end()) continue;
    const SceneNode& k = it->second;
    if (k.isModal && k.tag != scope) continue;  // its own surface
    out.add(TextBounds(nodes, scope, k, cx + (float)k.layoutMetrics.frame.origin.x,
                       cy + (float)k.layoutMetrics.frame.origin.y));
  }
  if (n.overflowHidden) out.clip(nx, ny, nx + w, ny + h);
  return out;
}

struct Landing {
  const SceneNode* node = nullptr;
  float x = 0, y = 0;
};

// The selectable paragraph a point lands in, walking down from `n`. At each
// level: (1) the topmost child whose text contains the point; else (2) the
// child whose text spans the point's y, nearest in x (a point left or right of
// a line); else (3) the nearest text BELOW the point, which the leaf resolves
// to its start, or when nothing is below, the lowest text above, resolved to
// its end. (3) is Blink's rule for a point in the gap between two blocks.
bool Land(const NodeMap& nodes, react::Tag scope, const SceneNode& n, float nx, float ny,
          float x, float y, Landing* out) {
  if (IsSelectableText(n)) {
    *out = Landing{&n, x, y};
    return true;
  }
  const float w = (float)n.layoutMetrics.frame.size.width;
  const float h = (float)n.layoutMetrics.frame.size.height;
  // A clipping node shows only its box: a point outside it resolves against
  // the edge it left by, so a drag below a chat list stops at the last
  // VISIBLE line instead of reaching rows scrolled out of view.
  if (n.overflowHidden && w > 0.0f && h > 0.0f) {
    x = std::clamp(x, nx, nx + w - 0.5f);
    y = std::clamp(y, ny, ny + h - 0.5f);
  }
  float cx, cy;
  ChildOrigin(n, nx, ny, &cx, &cy);
  struct Cand {
    const SceneNode* n;
    float ox, oy;
    Box b;
  };
  std::vector<Cand> cands;
  for (react::Tag c : n.children) {
    auto it = nodes.find(c);
    if (it == nodes.end()) continue;
    const SceneNode& k = it->second;
    if (k.isModal && k.tag != scope) continue;
    const float kx = cx + (float)k.layoutMetrics.frame.origin.x;
    const float ky = cy + (float)k.layoutMetrics.frame.origin.y;
    Box b = TextBounds(nodes, scope, k, kx, ky);
    if (!b.empty) cands.push_back(Cand{&k, kx, ky, b});
  }
  if (cands.empty()) return false;
  const Cand* pick = nullptr;
  for (auto it = cands.rbegin(); it != cands.rend() && !pick; ++it) {
    if (it->b.contains(x, y)) pick = &*it;  // (1) last painted = topmost
  }
  if (!pick) {  // (2)
    float best = std::numeric_limits<float>::max();
    for (const Cand& c : cands) {
      if (y < c.b.t || y >= c.b.b) continue;
      const float d = x < c.b.l ? c.b.l - x : (x >= c.b.r ? x - c.b.r : 0.0f);
      if (d < best) {
        best = d;
        pick = &c;
      }
    }
  }
  if (!pick) {  // (3)
    float bestTop = std::numeric_limits<float>::max();
    for (const Cand& c : cands) {
      if (c.b.t >= y && c.b.t < bestTop) {
        bestTop = c.b.t;
        pick = &c;
      }
    }
    if (!pick) {
      float bestBottom = std::numeric_limits<float>::lowest();
      for (const Cand& c : cands) {
        if (c.b.b > bestBottom) {
          bestBottom = c.b.b;
          pick = &c;
        }
      }
    }
  }
  return pick && Land(nodes, scope, *pick->n, pick->ox, pick->oy, x, y, out);
}

}  // namespace

react::Tag SceneGraph::textSelScopeLocked(react::Tag tag) {
  react::Tag cur = tag, last = 0;
  for (int guard = 0; cur != 0 && guard < 4096; ++guard) {
    auto it = nodes_.find(cur);
    if (it == nodes_.end()) break;
    last = cur;
    if (it->second.isModal) return cur;  // A22: a modal is its own surface
    if (it->second.parent == cur) break;
    cur = it->second.parent;
  }
  return last;
}

bool SceneGraph::textPositionAt(react::Tag anchorTag, float x, float y, react::Tag* tag,
                                size_t* offset) {
  std::lock_guard<std::mutex> lock(mutex_);
  const react::Tag scope = textSelScopeLocked(anchorTag);
  auto it = nodes_.find(scope);
  if (it == nodes_.end()) return false;
  const SceneNode& s = it->second;
  // Same origins as paint: a modal sits at window (0,0) (paintModalsLocked),
  // a root at its own frame origin (hitTestLocked).
  const float sx = s.isModal ? 0.0f : (float)s.layoutMetrics.frame.origin.x;
  const float sy = s.isModal ? 0.0f : (float)s.layoutMetrics.frame.origin.y;
  Landing hit;
  if (!Land(nodes_, scope, s, sx, sy, x, y, &hit)) return false;
  *tag = hit.node->tag;
  *offset = textOffsetAtLocked(*hit.node, hit.x, hit.y, true);
  return true;
}

void SceneGraph::setTextSelection(react::Tag tag, size_t anchor, size_t caret) {
  setTextSelectionRange(tag, anchor, tag, caret);
}

void SceneGraph::setTextSelectionRange(react::Tag anchorTag, size_t anchor,
                                       react::Tag focusTag, size_t focus) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (anchorTag == textSelTag_ && anchor == textSelAnchor_ && focusTag == textSelFocusTag_ &&
      focus == textSelCaret_) {
    return;
  }
  textSelTag_ = anchorTag;
  textSelAnchor_ = anchor;
  textSelFocusTag_ = focusTag;
  textSelCaret_ = focus;
  textSelPartsVersion_ = ~0ull;
  // P12-01: the highlight moved -- scene damage, or an idle window never
  // repaints it (the same rule setTextInputSelection follows).
  bumpVersion();
}

void SceneGraph::clearTextSelection() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (textSelTag_ == 0 && textSelFocusTag_ == 0) return;
  textSelTag_ = textSelFocusTag_ = 0;
  textSelAnchor_ = textSelCaret_ = 0;
  textSelPartsVersion_ = ~0ull;
  bumpVersion();  // P12-01: the highlight disappears
}

const std::vector<SceneGraph::TextSelPart>& SceneGraph::textSelPartsLocked() {
  const uint64_t v = version_.load(std::memory_order_acquire);
  if (v == textSelPartsVersion_) return textSelParts_;
  textSelPartsVersion_ = v;
  textSelParts_.clear();
  auto a = nodes_.find(textSelTag_);
  auto f = nodes_.find(textSelFocusTag_);
  if (a == nodes_.end() || f == nodes_.end()) return textSelParts_;
  if (textSelTag_ == textSelFocusTag_) {
    const size_t n = JoinedRuns(a->second).size();
    const size_t lo = std::min(std::min(textSelAnchor_, textSelCaret_), n);
    const size_t hi = std::min(std::max(textSelAnchor_, textSelCaret_), n);
    if (lo < hi) textSelParts_.push_back(TextSelPart{textSelTag_, lo, hi});
    return textSelParts_;
  }
  // Document order: the scope's subtree, depth first, children in order.
  const react::Tag scope = textSelScopeLocked(textSelTag_);
  std::vector<react::Tag> order;
  std::function<void(react::Tag)> walk = [&](react::Tag t) {
    auto it = nodes_.find(t);
    if (it == nodes_.end()) return;
    const SceneNode& n = it->second;
    if (n.isModal && t != scope) return;
    if (IsSelectableText(n)) order.push_back(t);
    for (react::Tag c : n.children) walk(c);
  };
  walk(scope);
  auto ia = std::find(order.begin(), order.end(), textSelTag_);
  auto iff = std::find(order.begin(), order.end(), textSelFocusTag_);
  if (ia == order.end() || iff == order.end()) return textSelParts_;
  const bool forward = ia < iff;
  const react::Tag firstTag = forward ? textSelTag_ : textSelFocusTag_;
  const size_t firstOff = forward ? textSelAnchor_ : textSelCaret_;
  const react::Tag lastTag = forward ? textSelFocusTag_ : textSelTag_;
  const size_t lastOff = forward ? textSelCaret_ : textSelAnchor_;
  for (auto it = forward ? ia : iff; it != order.end(); ++it) {
    const size_t n = JoinedRuns(nodes_.at(*it)).size();
    size_t lo = 0, hi = n;
    if (*it == firstTag) lo = std::min(firstOff, n);
    if (*it == lastTag) hi = std::min(lastOff, n);
    if (lo < hi) textSelParts_.push_back(TextSelPart{*it, lo, hi});
    if (*it == lastTag) break;
  }
  return textSelParts_;
}

bool SceneGraph::textSelRangeLocked(react::Tag tag, size_t* lo, size_t* hi) {
  for (const TextSelPart& p : textSelPartsLocked()) {
    if (p.tag == tag) {
      *lo = p.lo;
      *hi = p.hi;
      return true;
    }
  }
  return false;
}

react::Tag SceneGraph::textSelectionTag() {
  std::lock_guard<std::mutex> lock(mutex_);
  return textSelPartsLocked().empty() ? 0 : textSelTag_;
}

std::string SceneGraph::selectedText() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::string out;
  const SceneNode* prev = nullptr;
  std::string prevText;
  for (const TextSelPart& p : textSelPartsLocked()) {
    const SceneNode& n = nodes_.at(p.tag);
    const std::string text = JoinedRuns(n);
    if (prev != nullptr && !sameLineLocked(*prev, prevText, n)) out += '\n';
    out += text.substr(p.lo, p.hi - p.lo);
    prev = &n;
    prevText = text;
  }
  return out;
}

// ENG-43 (b): may a copy join paragraph `b` straight onto `a` (the part
// before it), with no newline? Yes when they read as one line of text:
//   1. siblings of a flexDirection-row parent the mount kept (an opaque row,
//      or collapsable={false});
//   2. side by side: b starts right of a, overlapping its band, with at most
//      half a line of gap (a styled line drawn as one Text per word);
//   3. a soft wrap of such a row: a ends in a space or NBSP, and b starts
//      the very next row at or left of a's start.
// Fabric FLATTENS a layout-only row View (Jim's HStack), so its Text children
// mount as siblings of whatever surrounds the row: rule 1 never sees it, and
// 2/3 read the row back from the geometry instead.
bool SceneGraph::sameLineLocked(const SceneNode& a, const std::string& aText,
                                const SceneNode& b) {
  auto pa = nodes_.find(a.parent);
  if (a.parent == b.parent && pa != nodes_.end() && pa->second.flexRow) return true;
  float ax = 0, ay = 0, bx = 0, by = 0;
  if (!absoluteOriginLocked(a.tag, &ax, &ay) || !absoluteOriginLocked(b.tag, &bx, &by)) {
    return false;
  }
  const float aw = (float)a.layoutMetrics.frame.size.width;
  const float ah = (float)a.layoutMetrics.frame.size.height;
  const float bh = (float)b.layoutMetrics.frame.size.height;
  const float halfLine = 0.5f * std::min(ah, bh);
  const float overlap = std::min(ay + ah, by + bh) - std::max(ay, by);
  if (overlap >= halfLine && bx >= ax + 0.5f * aw && bx - (ax + aw) <= halfLine) return true;
  const bool spaceEnd =
      (!aText.empty() && (aText.back() == ' ' || aText.back() == '\t')) ||
      (aText.size() >= 2 && (unsigned char)aText[aText.size() - 2] == 0xC2 &&
       (unsigned char)aText.back() == 0xA0);  // U+00A0, Jim's words()
  return spaceEnd && by >= ay + halfLine && by - (ay + ah) < halfLine && bx <= ax + 0.5f;
}

std::string SceneGraph::textSelectionReport() {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto& parts = textSelPartsLocked();
  std::string out = "text_selection_parts=" + std::to_string(parts.size()) + " tags=";
  for (size_t i = 0; i < parts.size(); ++i) {
    if (i) out += ',';
    out += std::to_string((int)parts[i].tag) + ":" + std::to_string(parts[i].lo) + "-" +
           std::to_string(parts[i].hi);
  }
  return out;
}

}  // namespace rni
