// Style-coverage A22 / parity item 26: <Modal> as an overlay surface.
// ModalHostView nodes are skipped by the tree walks (paintNode/hitTestNode
// return early unless modalWalk_ names them) and handled here instead: painted
// after the app root, hit-tested before it, always at window (0,0).
#include "scenegraph/SceneGraph.h"

#include <cstdio>

#include <react/renderer/components/FBReactNativeSpec/EventEmitters.h>

namespace rni {

namespace react = facebook::react;

int SceneGraph::paint(ImpellerDisplayListBuilder builder, float pointScaleFactor,
                      RasterJobs* jobs, FrameDamage* damage,
                      ImpellerDisplayListBuilder culled) {
  std::vector<react::EventEmitter::Shared> shows;
  int painted;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    painted = paintLocked(builder, pointScaleFactor, &shows, jobs);
    // FP-18: under the walk's lock, so no mark lands between walk and diff.
    FrameDamage unused;
    damage_.EndWalk(damage ? damage : &unused,
                    [this](int tag) { return nodes_.count(tag) > 0; });
    if (culled && damage && damage->partial && damage->w > 0 && damage->h > 0) {
      // Per-frame outputs of the walk stay the full walk's.
      const int fullPainted = painted_, fullSprites = spritesDrawn_;
      const bool spinning = spinnerAnimating_.load(std::memory_order_relaxed);
      cullActive_ = true;
      cullBox_.l = (float)damage->x;
      cullBox_.t = (float)damage->y;
      cullBox_.r = (float)(damage->x + damage->w);
      cullBox_.b = (float)(damage->y + damage->h);
      cullBox_.empty = false;
      std::vector<react::EventEmitter::Shared> again;
      paintLocked(culled, pointScaleFactor, &again, jobs);
      cullActive_ = false;
      painted_ = fullPainted;
      spritesDrawn_ = fullSprites;
      spinnerAnimating_.store(spinning, std::memory_order_relaxed);
    }
  }
  // onShow once the modal has been painted; dispatched outside mutex_.
  for (const auto& e : shows) {
    if (auto m = std::dynamic_pointer_cast<const react::ModalHostViewEventEmitter>(e))
      m->onShow({});
  }
  return painted;
}

void SceneGraph::collectModalsLocked(react::Tag tag, std::vector<react::Tag>* out) const {
  auto it = nodes_.find(tag);
  if (it == nodes_.end()) return;
  if (it->second.isModal && it->second.modalVisible) out->push_back(tag);
  for (auto child : it->second.children) collectModalsLocked(child, out);
}

void SceneGraph::paintModalsLocked(ImpellerDisplayListBuilder builder) {
  std::vector<react::Tag> modals;
  for (auto r : roots_) collectModalsLocked(r, &modals);
  // Tree order: a later modal presents over an earlier one.
  for (auto tag : modals) {
    const SceneNode& n = nodes_.at(tag);
    const auto& f = n.layoutMetrics.frame;
    modalWalk_ = tag;
    paintNode(builder, n, -(float)f.origin.x, -(float)f.origin.y);
    modalWalk_ = 0;
  }
}

void SceneGraph::collectModalShowsLocked(std::vector<react::EventEmitter::Shared>* shows) {
  std::vector<react::Tag> modals;
  for (auto r : roots_) collectModalsLocked(r, &modals);
  for (auto tag : modals) {
    SceneNode& n = nodes_.at(tag);
    if (n.modalShown) continue;
    n.modalShown = true;
    std::printf("[modal] show tag=%d transparent=%d\n", tag, (int)n.modalTransparent);
    std::fflush(stdout);
    if (n.eventEmitter && shows) shows->push_back(n.eventEmitter);
  }
}

react::Tag SceneGraph::hitTestLocked(float x, float y) {
  std::vector<react::Tag> modals;
  for (auto r : roots_) collectModalsLocked(r, &modals);
  // A visible modal covers the window: its subtree or the modal itself takes
  // the point, and nothing under it does (transparent or not, as on iOS).
  if (!modals.empty()) {
    const react::Tag top = modals.back();
    const SceneNode& n = nodes_.at(top);
    const auto& f = n.layoutMetrics.frame;
    modalWalk_ = top;
    const react::Tag hit = hitTestNode(n, -(float)f.origin.x, -(float)f.origin.y, x, y);
    modalWalk_ = 0;
    return hit ? hit : top;
  }
  // Roots in reverse: a later root paints over an earlier one.
  for (auto it = roots_.rbegin(); it != roots_.rend(); ++it) {
    auto root = nodes_.find(*it);
    if (root == nodes_.end()) continue;
    if (auto hit = hitTestNode(root->second, 0, 0, x, y)) return hit;
  }
  return 0;
}

react::Tag SceneGraph::topModal(react::EventEmitter::Shared* emitter) {
  std::lock_guard<std::mutex> lock(mutex_);
  std::vector<react::Tag> modals;
  for (auto r : roots_) collectModalsLocked(r, &modals);
  if (modals.empty()) return 0;
  if (emitter) *emitter = nodes_.at(modals.back()).eventEmitter;
  return modals.back();
}

}  // namespace rni
