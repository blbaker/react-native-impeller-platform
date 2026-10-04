// ENG-09 — WorldRasterStore.
//
// ONE thread-safe map from an application-chosen string id to the most
// recent RGBA buffer for that id, keyed by a monotonic version counter. This
// is the hand-off point between WorldRasterModule (JS calls setPixels off
// the render thread) and SceneGraph's world painter (reads on the render
// thread, once per frame, deciding whether to re-upload based on version).
//
// ⛔ THE STORE OWNS THE BYTES; NOBODY ELSE MAY HOLD A LONG-LIVED POINTER INTO
// THEM. get() returns a COPY of the shared_ptr<const Entry>, which is safe
// to read after the lock is released because Entry is never mutated after
// publish -- setPixels always builds a brand-new Entry and swaps it in. A
// reader that took a reference into the map's storage instead would race
// setPixels replacing that slot from another thread.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace rni {

struct WorldRasterEntry {
  uint64_t version = 0;
  double width = 0;
  double height = 0;
  std::vector<uint8_t> pixels;  // tightly packed RGBA8, width*height*4 bytes
};

// ENG-10. One quad in a drawSprites list: which registered atlas texture, where
// (in the <world> node's own layout points, top-left origin), and a per-sprite
// opacity in [0,1]. The list order IS the paint order (back-to-front).
struct WorldSprite {
  std::string textureId;
  float x = 0, y = 0, w = 0, h = 0;
  float alpha = 1.0f;
};

struct WorldSpriteList {
  uint64_t version = 0;
  std::vector<WorldSprite> sprites;
};

class WorldRasterStore {
 public:
  // Replaces whatever is stored at `id` with a new entry and bumps the
  // version. The version is store-global-per-id monotonic, not derived from
  // the caller, so two rapid setPixels calls for the same id can never be
  // observed out of order by a reader that only compares versions.
  void setPixels(const std::string& id, std::vector<uint8_t> pixels,
                 double width, double height) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto entry = std::make_shared<WorldRasterEntry>();
      auto it = entries_.find(id);
      entry->version = (it == entries_.end() ? 0 : it->second->version) + 1;
      entry->width = width;
      entry->height = height;
      entry->pixels = std::move(pixels);
      entries_[id] = std::move(entry);
    }
    // ⛔ FIRE THE DAMAGE HOOK AFTER RELEASING mutex_, NEVER WHILE HOLDING IT.
    // ENG-09/P12-01 wake: a store write is scene damage the SceneGraph version
    // counter cannot see on its own (setPixels runs on the JS thread and never
    // touches the scene graph). Without this the windowed idle-skip loop
    // (main.cpp:834) sleeps in glfwWaitEventsTimeout and the new pixels never
    // present — the animation freezes on the last painted frame, exactly the
    // off-thread-producer case a Fabric-commit-only version bump is blind to.
    // The host wires this to sceneGraph.bumpVersion(), which advances version_
    // (so the next frame is dirty) AND fires damageWake_ (so a sleeping loop
    // wakes). Copied and called outside the lock: the hook takes SceneGraph's
    // wakeMutex_, never this store's mutex_, but a reader that grabbed the hook
    // could re-enter and we must not hold mutex_ across foreign code.
    fireDamage();
  }

  // ENG-10. Registers (or replaces) one sprite-atlas texture. Same immutable-
  // Entry publish as setPixels, but a SEPARATE map: atlas ids and <world> ids
  // are different namespaces, so a sprite called "bg" can never clobber the
  // world buffer called "bg". Pixels arrive PREMULTIPLIED (the module does it).
  void registerSprite(const std::string& textureId, std::vector<uint8_t> pixels,
                      double width, double height) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto entry = std::make_shared<WorldRasterEntry>();
      auto it = atlas_.find(textureId);
      entry->version = (it == atlas_.end() ? 0 : it->second->version) + 1;
      entry->width = width;
      entry->height = height;
      entry->pixels = std::move(pixels);
      atlas_[textureId] = std::move(entry);
    }
    fireDamage();
  }

  // ENG-10. Replaces the sprite list painted over <world name=id>. Per-frame
  // hot path: a new list is scene damage exactly like a setPixels write, so it
  // MUST fire the same hook or the windowed idle-skip loop sleeps and the
  // sprites freeze on the last presented frame.
  void setSprites(const std::string& id, std::vector<WorldSprite> sprites) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto list = std::make_shared<WorldSpriteList>();
      auto it = spriteLists_.find(id);
      list->version = (it == spriteLists_.end() ? 0 : it->second->version) + 1;
      list->sprites = std::move(sprites);
      spriteLists_[id] = std::move(list);
    }
    fireDamage();
  }

  // ENG-21. Per-<world> texture sampling: true = nearest-neighbour for the
  // setPixels terrain AND every sprite drawn on that world. Default (never
  // set) is linear, the pre-ENG-21 behaviour. Pixel art at an integer scale
  // needs nearest, or every art-pixel edge blends over ~1 screen px.
  void setSampling(const std::string& id, bool nearest) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      nearest_[id] = nearest;
    }
    fireDamage();
  }

  bool isNearest(const std::string& id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = nearest_.find(id);
    return it != nearest_.end() && it->second;
  }

  std::shared_ptr<const WorldRasterEntry> getSprite(
      const std::string& textureId) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = atlas_.find(textureId);
    return it == atlas_.end() ? nullptr : it->second;
  }

  std::shared_ptr<const WorldSpriteList> getSprites(const std::string& id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = spriteLists_.find(id);
    return it == spriteLists_.end() ? nullptr : it->second;
  }

  // Install the hook fired after every setPixels publish. Guarded by its OWN
  // mutex (never mutex_) so a write path holding mutex_ cannot invert lock
  // order against a caller installing the hook. Null until a windowed
  // idle-skip host installs it; a headless / --frames run leaves it unset and
  // setPixels is unchanged.
  void setDamageHook(std::function<void()> hook) {
    std::lock_guard<std::mutex> lock(hookMutex_);
    damageHook_ = std::move(hook);
  }

  // Returns nullptr if `id` has never been set. Callers must NOT mutate the
  // returned Entry -- it is shared with the store and with any other reader
  // that grabbed the same shared_ptr in the same frame.
  std::shared_ptr<const WorldRasterEntry> get(const std::string& id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = entries_.find(id);
    if (it == entries_.end()) return nullptr;
    return it->second;
  }

 private:
  // Copied and called OUTSIDE mutex_ -- see the comment in setPixels.
  void fireDamage() {
    std::function<void()> hook;
    {
      std::lock_guard<std::mutex> lock(hookMutex_);
      hook = damageHook_;
    }
    if (hook) hook();
  }

  mutable std::mutex mutex_;
  std::unordered_map<std::string, std::shared_ptr<const WorldRasterEntry>>
      entries_;
  // ENG-10 sprite atlas (textureId -> premultiplied RGBA) and per-<world>
  // sprite lists (world id -> back-to-front quads). Guarded by mutex_.
  std::unordered_map<std::string, std::shared_ptr<const WorldRasterEntry>>
      atlas_;
  std::unordered_map<std::string, std::shared_ptr<const WorldSpriteList>>
      spriteLists_;
  std::unordered_map<std::string, bool> nearest_;  // ENG-21
  // P12-01/ENG-09 damage wake. Separate mutex from mutex_ so setPixels, which
  // fires the hook, and setDamageHook cannot deadlock or invert lock order.
  mutable std::mutex hookMutex_;
  std::function<void()> damageHook_;
};

}  // namespace rni
