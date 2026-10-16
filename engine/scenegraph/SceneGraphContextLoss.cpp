// FP-32: SceneGraph's half of context-loss recovery (host/ContextLoss.h).
#include "scenegraph/SceneGraph.h"

#include <cstdio>
#include <mutex>

namespace rni {

void SceneGraph::dropGpuResources() {
  std::lock_guard<std::mutex> lock(mutex_);
  const size_t images = imageTextures_.Clear();
  const size_t svgs = svgCache_.size();
  for (auto& [key, entry] : svgCache_) {
    if (entry.texture) ImpellerTextureRelease(entry.texture);
  }
  svgCache_.clear();
  svgCacheOrder_.clear();
  const size_t worlds = worldTextureCache_.size();
  for (auto& [tag, entry] : worldTextureCache_) {
    if (entry.slot.texture) ImpellerTextureRelease(entry.slot.texture);
  }
  worldTextureCache_.clear();  // uploadedVersion goes with it: the store re-uploads
  const size_t sprites = spriteTextureCache_.size();
  for (auto& [id, entry] : spriteTextureCache_) {
    if (entry.slot.texture) ImpellerTextureRelease(entry.slot.texture);
  }
  spriteTextureCache_.clear();
  const int tree = treeTexture_ != nullptr ? 1 : 0;
  if (treeTexture_) ImpellerTextureRelease(treeTexture_);
  treeTexture_ = nullptr;
  std::printf("rn-impeller: context_loss_drop images=%zu svg=%zu world=%zu sprites=%zu tree=%d\n",
              images, svgs, worlds, sprites, tree);
  std::fflush(stdout);
}

}  // namespace rni
