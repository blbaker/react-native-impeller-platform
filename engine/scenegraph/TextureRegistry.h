// FP-42: external textures (video, camera, test producers) by id.
//
// Model: flutter/common/graphics/texture.{h,cc} (Texture + TextureRegistry),
// flow/layers/texture_layer.cc (paint the latest frame inside the layer's
// mutators) and shell/platform/embedder/embedder_external_texture_gl.cc
// (MarkNewFrameAvailable drops the cached image; Paint resolves a new one only
// when none is cached). Flutter registers on the raster thread through posted
// tasks; here every call takes the registry's mutex instead, because our
// producers and the JS TurboModule have no raster task runner to post to.
//
// A producer subclasses ExternalTexture and returns its latest frame from
// CopyFrame(): CPU RGBA (premultiplied, top row first, the
// FlPixelBufferTexture copy_pixels contract) or a backend ImpellerTexture
// (the FlTextureGL populate contract; the frame owns one reference).
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <vector>

#include "impeller.h"

namespace rni {

struct ExternalFrame {
  ExternalFrame() = default;
  ExternalFrame(const ExternalFrame&) = delete;
  ExternalFrame& operator=(const ExternalFrame&) = delete;
  ~ExternalFrame() {
    if (texture) ImpellerTextureRelease(texture);
  }
  uint64_t seq = 0;            // producer's frame number, monotonic
  int width = 0, height = 0;   // pixels
  std::vector<uint8_t> rgba;   // premultiplied RGBA8, width*height*4; empty = backend texture
  ImpellerTexture texture{nullptr};  // backend texture (one reference owned here)
};

class ExternalTexture {
 public:
  explicit ExternalTexture(int64_t id) : id_(id) {}
  virtual ~ExternalTexture() = default;
  int64_t id() const { return id_; }
  // Any thread, never under the producer's own lock when it calls the registry.
  // Null = no frame yet (Flutter: TextureLayer paints nothing).
  virtual std::shared_ptr<const ExternalFrame> CopyFrame() = 0;
  // After the registry dropped it; stop producing. Called without registry locks.
  virtual void OnUnregistered() {}

 private:
  int64_t id_;
};

class TextureRegistry {
 public:
  TextureRegistry() = default;
  ~TextureRegistry();  // unregisters (stops) every producer still registered
  TextureRegistry(const TextureRegistry&) = delete;
  TextureRegistry& operator=(const TextureRegistry&) = delete;

  int64_t NextId();
  void Register(std::shared_ptr<ExternalTexture> texture);
  bool Unregister(int64_t id);
  // Producer: a new frame is ready. Drops the cached frame and wakes a frame.
  void MarkFrameAvailable(int64_t id);

  struct Resolved {
    std::shared_ptr<const ExternalFrame> frame;  // null: unregistered or no frame
    uint64_t marks = 0;  // MarkFrameAvailable calls seen when it was resolved
  };
  // RECORD. Embedder Paint: re-resolves only after MarkFrameAvailable.
  Resolved Resolve(int64_t id);

  // Called after register / unregister / mark, outside the registry lock.
  // Cleared (nullptr) before the listener's owner dies; returns once no call runs.
  void SetFrameListener(std::function<void()> listener);

  size_t size() const;
  // `external_textures registered= unregistered= marks= resolves=` at exit.
  void PrintSummary() const;

 private:
  struct Entry {
    std::shared_ptr<ExternalTexture> texture;
    std::shared_ptr<const ExternalFrame> last;  // embedder last_image_
    bool dirty = true;
    uint64_t marks = 0;
  };
  void Notify();

  mutable std::mutex mu_;
  std::map<int64_t, Entry> entries_;
  int64_t nextId_ = 1;
  uint64_t registered_ = 0, unregistered_ = 0, marks_ = 0, resolves_ = 0;
  std::mutex listenerMu_;  // held while the listener runs
  std::function<void()> listener_;
};

// Test producer (FP-42 gate): a width x height pattern at `fps` on its own
// thread; stops producing (stays registered) after maxFrames when > 0.
// Frame k: top-left quadrant blue (0,0,255); the other three quadrants
// R = (k % 32) * 8, G = (k / 32 % 32) * 8, B = 0. RNI_EXT_TEXTURE_LOG=1 prints
// `ext_texture_produce id= seq= t_us=` per frame.
std::shared_ptr<ExternalTexture> MakeTestPatternTexture(TextureRegistry* registry, int64_t id,
                                                        double fps, int width, int height,
                                                        uint64_t maxFrames = 0);

bool ExternalTextureLog();  // RNI_EXT_TEXTURE_LOG=1

}  // namespace rni
