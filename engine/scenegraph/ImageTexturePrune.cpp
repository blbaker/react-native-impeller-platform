// memory audit: an unmounted <Image> kept its GPU texture for as long as its
// bitmap stayed in the decoded-image cache (100 MiB by default), so leaving an
// image-heavy screen gave no GPU memory back. The bitmap stays cached, so a
// remount uploads again without a decode; only the texture goes. The scan runs
// only after an image node was deleted or changed source.
#include "scenegraph/SceneGraph.h"

#include <cstdio>
#include <string>
#include <unordered_set>

namespace rni {

void SceneGraph::pruneImageTexturesLocked() {
  if (imageRefsPruned_ == imageRefsGen_) return;
  imageRefsPruned_ = imageRefsGen_;
  std::unordered_set<std::string> uris;
  for (const auto& [tag, node] : nodes_) {
    if (!node.isImage) continue;
    for (const auto& src : node.imgSources) uris.insert(src.uri);
    if (!node.imgDefaultUri.empty()) uris.insert(node.imgDefaultUri);
  }
  const size_t released = imageTextures_.ReleaseUnreferenced(uris);
  if (released == 0) return;
  std::printf("rn-impeller: image_texture_prune released=%zu mounted_uris=%zu\n", released, uris.size());
  std::fflush(stdout);
}

}  // namespace rni
