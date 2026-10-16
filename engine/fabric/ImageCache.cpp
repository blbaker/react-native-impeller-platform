#include "ImageCache.h"

namespace rni::image {

ImageCache& Cache() {
  static ImageCache* cache = new ImageCache();
  return *cache;
}

bool ImageCache::Get(const std::string& uri, const std::string& sizeKey,
                     std::shared_ptr<const Decoded>* out) {
  std::lock_guard<std::mutex> lock(mu_);
  auto u = slots_.find(uri);
  if (u == slots_.end()) return false;
  auto s = u->second.find(sizeKey);
  if (s == u->second.end()) return false;
  if (s->second.img) lru_.splice(lru_.begin(), lru_, s->second.pos);
  if (out) *out = s->second.img;
  return true;
}

std::shared_ptr<const Decoded> ImageCache::Put(const std::string& uri, const std::string& sizeKey,
                                               std::shared_ptr<const Decoded> img,
                                               const Headers& headers) {
  std::lock_guard<std::mutex> lock(mu_);
  seen_[uri] = headers;
  auto& bySize = slots_[uri];
  auto existing = bySize.find(sizeKey);
  if (existing != bySize.end()) {
    if (existing->second.img) lru_.splice(lru_.begin(), lru_, existing->second.pos);
    return existing->second.img;
  }
  Slot slot{img, lru_.end()};
  if (img) {
    const int64_t bytes = (int64_t)img->rgba.size();
    lru_.push_front({uri, sizeKey, bytes});
    slot.pos = lru_.begin();
    bytes_ += bytes;
    resident_.insert(img.get());
  }
  bySize.emplace(sizeKey, std::move(slot));
  // The entry just inserted stays even when it alone exceeds the budget: dropping it
  // would make the painter reload an image it is showing on every frame.
  TrimLocked(budget_, 1);
  if (bytes_ > peak_) peak_ = bytes_;
  return img;
}

std::shared_ptr<const Decoded> ImageCache::BestOther(const std::string& uri, float boxW, float boxH) {
  std::lock_guard<std::mutex> lock(mu_);
  auto u = slots_.find(uri);
  if (u == slots_.end()) return nullptr;
  Slot* best = nullptr;
  for (auto& [k, s] : u->second) {
    const auto& d = s.img;
    if (!d) continue;
    const bool covers = d->width >= boxW && d->height >= boxH;
    const bool bestCovers = best && best->img->width >= boxW && best->img->height >= boxH;
    const long long area = (long long)d->width * d->height;
    const long long bestArea = best ? (long long)best->img->width * best->img->height : -1;
    if (!best || (covers && (!bestCovers || area < bestArea)) || (!covers && !bestCovers && area > bestArea)) {
      best = &s;
    }
  }
  if (!best) return nullptr;
  lru_.splice(lru_.begin(), lru_, best->pos);
  return best->img;
}

bool ImageCache::HasImage(const std::string& uri) {
  std::lock_guard<std::mutex> lock(mu_);
  auto u = slots_.find(uri);
  if (u == slots_.end()) return false;
  for (const auto& [k, s] : u->second) if (s.img) return true;
  return false;
}

bool ImageCache::Seen(const std::string& uri, Headers* headers) {
  std::lock_guard<std::mutex> lock(mu_);
  auto it = seen_.find(uri);
  if (it == seen_.end()) return false;
  if (headers) *headers = it->second;
  return true;
}

void ImageCache::SetBudget(int64_t bytes) {
  std::lock_guard<std::mutex> lock(mu_);
  budget_ = bytes < 0 ? 0 : bytes;
  TrimLocked(budget_, 0);
}

void ImageCache::SetFloor(int64_t bytes) {
  std::lock_guard<std::mutex> lock(mu_);
  floor_ = bytes < 0 ? 0 : bytes;
}

int64_t ImageCache::Purge() {
  std::lock_guard<std::mutex> lock(mu_);
  const int64_t before = bytes_;
  TrimLocked(floor_, 0);
  return before - bytes_;
}

int64_t ImageCache::Bytes() {
  std::lock_guard<std::mutex> lock(mu_);
  return bytes_;
}

int64_t ImageCache::Peak() {
  std::lock_guard<std::mutex> lock(mu_);
  return peak_;
}

uint64_t ImageCache::Epoch() {
  std::lock_guard<std::mutex> lock(mu_);
  return epoch_;
}

bool ImageCache::IsResident(const Decoded* d) {
  std::lock_guard<std::mutex> lock(mu_);
  return resident_.count(d) > 0;
}

void ImageCache::EvictLocked(std::list<Node>::iterator it) {
  auto u = slots_.find(it->uri);
  if (u != slots_.end()) {
    auto s = u->second.find(it->sizeKey);
    if (s != u->second.end()) {
      resident_.erase(s->second.img.get());
      u->second.erase(s);
    }
    if (u->second.empty()) slots_.erase(u);
  }
  bytes_ -= it->bytes;
  lru_.erase(it);
  ++epoch_;
}

// Flutter _checkCacheSize: drop the oldest entries until the cache fits; `keep` entries always stay.
void ImageCache::TrimLocked(int64_t limit, size_t keep) {
  while (bytes_ > limit && lru_.size() > keep) EvictLocked(std::prev(lru_.end()));
}

}  // namespace rni::image
