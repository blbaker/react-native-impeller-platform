// SceneGraph::textureViewAt: which <ImpellerTextureView> (if any) is the
// topmost thing at a point. Uses the painter-ordered hitTestLocked walk, so an
// RN overlay drawn over a web view keeps its own events.
#include "scenegraph/SceneGraph.h"

namespace rni {

bool SceneGraph::textureViewAt(float x, float y, TextureViewHit* out) {
  std::lock_guard<std::mutex> lock(mutex_);
  const facebook::react::Tag tag = hitTestLocked(x, y);
  if (!tag) return false;
  auto it = nodes_.find(tag);
  if (it == nodes_.end() || !it->second.isExternalTexture || it->second.externalTextureId <= 0)
    return false;
  float ox = 0, oy = 0;
  if (!absoluteOriginLocked(tag, &ox, &oy)) return false;
  out->textureId = it->second.externalTextureId;
  out->x = ox;
  out->y = oy;
  out->w = (float)it->second.layoutMetrics.frame.size.width;
  out->h = (float)it->second.layoutMetrics.frame.size.height;
  return true;
}

}  // namespace rni
