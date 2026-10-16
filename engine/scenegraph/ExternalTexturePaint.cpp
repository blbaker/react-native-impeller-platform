// FP-42: <ImpellerTextureView> paint. Model: flow/layers/texture_layer.cc
// (TextureLayer::Paint: GetTexture(id), paint nothing when it is gone, else
// draw the latest frame into the layer bounds with the state stack's paint) and
// shell/platform/embedder/embedder_external_texture_gl.cc (DrawImageRect from
// the image bounds into the layer bounds).
#include "scenegraph/SceneGraph.h"

#include <cstdio>
#include <mutex>
#include <string>

namespace rni {

void SceneGraph::setTextureRegistry(std::shared_ptr<TextureRegistry> registry) {
  if (textureRegistry_) textureRegistry_->SetFrameListener(nullptr);
  textureRegistry_ = std::move(registry);
  // shell.cc OnPlatformViewMarkTextureFrameAvailable -> ScheduleFrame. Wake
  // only: the texture node is volatile damage every frame (TextureLayer::Diff).
  if (textureRegistry_) textureRegistry_->SetFrameListener([this] { bumpRevision(); });
}

std::string SceneGraph::takeExternalTextureNote() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::string out;
  out.swap(extTextureNote_);
  return out;
}

void SceneGraph::releaseExternalTextures() {
  for (auto& [tag, entry] : extTextureCache_) {
    if (entry.slot.texture) ImpellerTextureRelease(entry.slot.texture);
  }
  extTextureCache_.clear();
}

void SceneGraph::paintExternalTexture(ImpellerDisplayListBuilder builder, const SceneNode& node,
                                      float x, float y, float w, float h, float alpha) {
  if (textureRegistry_ == nullptr || w <= 0.0f || h <= 0.0f) return;
  const TextureRegistry::Resolved r = textureRegistry_->Resolve(node.externalTextureId);
  auto note = [&](uint64_t seq) {
    if (cullActive_) return;  // the culled walk repeats the full walk's draws
    if (extTextureNote_.size() > 4096) extTextureNote_.clear();  // nobody is reading
    if (!extTextureNote_.empty()) extTextureNote_ += ',';
    extTextureNote_ += std::to_string(node.externalTextureId) + ":" + std::to_string(seq) + ":" +
                       std::to_string(r.marks);
  };
  auto cached = extTextureCache_.find(node.tag);
  if (!r.frame) {
    // Unregistered (or no frame yet): paint nothing, and let the GPU copy go.
    if (cached != extTextureCache_.end()) {
      if (cached->second.slot.texture) ImpellerTextureRelease(cached->second.slot.texture);
      extTextureCache_.erase(cached);
    }
    note(0);
    return;
  }
  const ExternalFrame& f = *r.frame;
  if (f.width <= 0 || f.height <= 0) return;
  ImpellerTexture tex = f.texture;  // backend frame: the producer's own texture
  if (tex == nullptr) {
    if (f.rgba.size() < (size_t)f.width * f.height * 4 || gpu_.uploader == nullptr) return;
    WorldTextureEntry& e = extTextureCache_[node.tag];
    if (SlotStale(e.slot, f.width, f.height) || e.uploadedVersion != f.seq) {
      // The frame (immutable once published) owns the bytes until the GPU has them.
      if (!gpu_.uploader->Upload(e.slot, jobs_, f.width, f.height, f.rgba.data(), r.frame,
                                 UploadFlags{/*clampEdges=*/true, /*image=*/false})) {
        return;
      }
      e.uploadedVersion = f.seq;
    }
    tex = e.slot.texture;
  }
  if (tex == nullptr) return;
  ImpellerPaint paint = ImpellerPaintNew();
  const ImpellerColor base = {1.0f, 1.0f, 1.0f, alpha, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &base);
  const ImpellerRect src = {0.0f, 0.0f, (float)f.width, (float)f.height};
  const ImpellerRect dst = {x, y, w, h};
  ImpellerDisplayListBuilderDrawTextureRect(builder, tex, &src, &dst,
                                            kImpellerTextureSamplingLinear, paint);
  ImpellerPaintRelease(paint);
  note(f.seq);
}

}  // namespace rni
