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

class WorldRasterStore {
 public:
  // Replaces whatever is stored at `id` with a new entry and bumps the
  // version. The version is store-global-per-id monotonic, not derived from
  // the caller, so two rapid setPixels calls for the same id can never be
  // observed out of order by a reader that only compares versions.
  void setPixels(const std::string& id, std::vector<uint8_t> pixels,
                 double width, double height) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto entry = std::make_shared<WorldRasterEntry>();
    auto it = entries_.find(id);
    entry->version = (it == entries_.end() ? 0 : it->second->version) + 1;
    entry->width = width;
    entry->height = height;
    entry->pixels = std::move(pixels);
    entries_[id] = std::move(entry);
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
  mutable std::mutex mutex_;
  std::unordered_map<std::string, std::shared_ptr<const WorldRasterEntry>>
      entries_;
};

}  // namespace rni
