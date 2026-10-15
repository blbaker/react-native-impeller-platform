#pragma once

// FP-33: byte-budgeted LRU over the decoded <Image> bitmaps (model: Flutter's
// ImageCache, packages/flutter/lib/src/painting/image_cache.dart: 100 MiB
// default, _checkCacheSize evicts the least recently used key until the cache
// fits, clear() on memory pressure). A decoded bitmap is also what the painter's
// texture is made from, so the budget covers both: ImageTextures drops a texture
// once its bitmap is no longer resident (EvictionEpoch / IsResident).
// Own mutex; ImageStore calls in while holding its own (order: store, cache).

#include <cstdint>
#include <iterator>
#include <list>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>

#include "ImageStore.h"

namespace rni::image {

class ImageCache {
 public:
  static constexpr int64_t kDefaultBudget = 100ll << 20;  // Flutter _kDefaultSizeBytes

  // True when the slot exists (a failed local decode is a present null slot); touches the LRU.
  bool Get(const std::string& uri, const std::string& sizeKey, std::shared_ptr<const Decoded>* out);
  // Inserts (or returns the existing slot's image) and evicts down to the budget.
  std::shared_ptr<const Decoded> Put(const std::string& uri, const std::string& sizeKey,
                                     std::shared_ptr<const Decoded> img, const Headers& headers);
  // The smallest cached size of `uri` covering the box, else the largest; touches it.
  std::shared_ptr<const Decoded> BestOther(const std::string& uri, float boxW, float boxH);
  bool HasImage(const std::string& uri);
  // Headers a uri was last loaded with; false when it was never cached.
  bool Seen(const std::string& uri, Headers* headers);

  void SetBudget(int64_t bytes);
  void SetFloor(int64_t bytes);
  // Evicts the least recently used entries until at most the floor is left; returns bytes freed.
  int64_t Purge();
  int64_t Bytes();
  int64_t Peak();  // most bytes held after any insert was trimmed
  uint64_t Epoch();
  bool IsResident(const Decoded* d);

 private:
  struct Node {
    std::string uri, sizeKey;
    int64_t bytes;
  };
  struct Slot {
    std::shared_ptr<const Decoded> img;
    std::list<Node>::iterator pos;
  };
  void EvictLocked(std::list<Node>::iterator it);
  void TrimLocked(int64_t limit, size_t keep);

  std::mutex mu_;
  std::unordered_map<std::string, std::unordered_map<std::string, Slot>> slots_;
  std::unordered_map<std::string, Headers> seen_;
  std::unordered_set<const Decoded*> resident_;
  std::list<Node> lru_;  // front = most recently used
  int64_t bytes_{0}, peak_{0}, budget_{kDefaultBudget}, floor_{0};
  uint64_t epoch_{0};
};

ImageCache& Cache();  // the process-wide cache (leaked: decode workers outlive static teardown)

}  // namespace rni::image
