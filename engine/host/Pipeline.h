// FP-13: the hand-off between RECORD (producer) and RASTER (consumer).
//
// Model: flutter/shell/common/pipeline.h at our SDK pin. A fixed number of
// slots (`depth`) guarded by two counting semaphores: `empty_` (slots a
// producer may reserve) and `available_` (finished items a consumer may take).
// Produce() reserves a slot and hands back a ProducerContinuation; the producer
// builds its item and calls Complete(item); a continuation dropped without
// Complete releases its slot. Consume() takes the oldest item, runs the
// consumer, then frees the slot. Depth comes from shell/common/animator.cc:
// 2 when the raster thread is separate, 1 when platform == raster (non-Metal),
// which is every mode until FP-15 adds the raster thread.
//
// Semaphores are a mutex + counter (fml::Semaphore is a platform semaphore;
// only TryWait/Signal are used, so nothing here blocks).
#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <utility>

namespace rni {

struct PipelineProduceResult {
  bool success = false;
  bool is_first_item = false;  // only valid when success
};

enum class PipelineConsumeResult { kNoneAvailable, kDone, kMoreAvailable };

// Flutter's Animator rule (non-Metal): one slot when the platform thread also
// rasterizes, two when a raster thread consumes concurrently.
inline uint32_t PipelineDepthFor(bool platformIsRaster) {
  return platformIsRaster ? 1u : 2u;
}

template <class R>
class Pipeline {
 public:
  using ResourcePtr = std::unique_ptr<R>;
  using Consumer = std::function<void(ResourcePtr)>;

  class ProducerContinuation {
   public:
    ProducerContinuation() = default;
    ProducerContinuation(ProducerContinuation&& o) noexcept
        : pipeline_(std::exchange(o.pipeline_, nullptr)) {}
    ProducerContinuation& operator=(ProducerContinuation&& o) noexcept {
      std::swap(pipeline_, o.pipeline_);
      return *this;
    }
    ProducerContinuation(const ProducerContinuation&) = delete;
    ProducerContinuation& operator=(const ProducerContinuation&) = delete;
    ~ProducerContinuation() {
      if (pipeline_) pipeline_->ProducerAbandon();  // slot back, nothing queued
    }

    [[nodiscard]] PipelineProduceResult Complete(ResourcePtr resource) {
      if (!pipeline_) return {};
      Pipeline* p = std::exchange(pipeline_, nullptr);
      if (!resource) {
        p->ProducerAbandon();
        return {};
      }
      return p->ProducerCommit(std::move(resource));
    }
    explicit operator bool() const { return pipeline_ != nullptr; }

   private:
    friend class Pipeline;
    explicit ProducerContinuation(Pipeline* p) : pipeline_(p) {}
    Pipeline* pipeline_ = nullptr;
  };

  explicit Pipeline(uint32_t depth) : depth_(depth), empty_(depth) {}
  Pipeline(const Pipeline&) = delete;
  Pipeline& operator=(const Pipeline&) = delete;

  // An empty continuation when every slot is reserved or queued (Flutter's
  // Animator then skips the frame: "Pipeline full").
  ProducerContinuation Produce() {
    std::lock_guard<std::mutex> lock(mu_);
    if (empty_ == 0) {
      ++produceRefused_;
      return {};
    }
    --empty_;
    ++inflight_;
    if (inflight_ > maxInflight_) maxInflight_ = inflight_;
    return ProducerContinuation(this);
  }

  [[nodiscard]] PipelineConsumeResult Consume(const Consumer& consumer) {
    if (!consumer) return PipelineConsumeResult::kNoneAvailable;
    ResourcePtr resource;
    size_t left = 0;
    {
      std::lock_guard<std::mutex> lock(mu_);
      if (queue_.empty()) return PipelineConsumeResult::kNoneAvailable;
      resource = std::move(queue_.front());
      queue_.pop_front();
      left = queue_.size();
    }
    consumer(std::move(resource));
    {
      std::lock_guard<std::mutex> lock(mu_);
      ++empty_;
      --inflight_;
      ++consumed_;
    }
    return left > 0 ? PipelineConsumeResult::kMoreAvailable
                    : PipelineConsumeResult::kDone;
  }

  struct Stats {
    uint32_t depth;
    uint64_t produced, consumed, abandoned, refused;
    uint32_t maxInflight;
  };
  Stats stats() const {
    std::lock_guard<std::mutex> lock(mu_);
    return {depth_, produced_, consumed_, abandoned_, produceRefused_, maxInflight_};
  }

 private:
  PipelineProduceResult ProducerCommit(ResourcePtr resource) {
    std::lock_guard<std::mutex> lock(mu_);
    const bool first = queue_.empty();
    queue_.push_back(std::move(resource));
    ++produced_;
    return {true, first};
  }
  void ProducerAbandon() {
    std::lock_guard<std::mutex> lock(mu_);
    ++empty_;
    --inflight_;
    ++abandoned_;
  }

  const uint32_t depth_;
  mutable std::mutex mu_;
  uint32_t empty_;
  uint32_t inflight_ = 0;
  uint32_t maxInflight_ = 0;
  uint64_t produced_ = 0, consumed_ = 0, abandoned_ = 0, produceRefused_ = 0;
  std::deque<ResourcePtr> queue_;
};

}  // namespace rni
