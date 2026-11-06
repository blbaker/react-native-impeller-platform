// Row 3 video, linux: the player's sound thread (video/FfmpegPlayer.h). No
// ffmpeg headers: chunks come from the copy's Decoder, already in the sink's
// format, and go to an AudioSink (ALSA).
//
// The video media clock is the master. A sample with media time `at`, written
// now, is heard at media time now + sink delay, so the thread keeps
//   at - (media + delay)
// within kSyncTolerance: further behind and the late part is skipped, further
// ahead and it waits for the clock. Paused, loading or seeking: the device is
// emptied at once. Rate not 1: muted (no pitch-keeping time stretch), and the
// chunks the clock passes are consumed so sound resumes in sync at rate 1.
#include <algorithm>
#include <cmath>
#include <cstdio>

#include "video/AudioSink.h"
#include "video/FfmpegPlayer.h"

namespace rni::ffv {
namespace {

constexpr double kSyncTolerance = 0.040;  // about one video frame
constexpr double kMaxWaitSec = 0.050;     // re-check state at least this often while waiting
constexpr int kWriteFrames = 1024;        // per device write: pause and seek stay prompt

}  // namespace

void FfmpegVideo::StartAudio() {
  const std::string why = dec_->AudioUnavailable();
  if (why.empty()) {
    audioThread_ = std::thread([this] { AudioRun(); });
    return;
  }
  if (why == "no audio stream") return;  // status stays "none"
  AudioFail(why);
}

void FfmpegVideo::AudioFail(const std::string& why) {
  std::lock_guard<std::mutex> lock(mu_);
  audio_ = "error: " + why;
  std::printf("rn-impeller: video id=%lld audio off: %s\n", (long long)id(), why.c_str());
  std::fflush(stdout);
}

void FfmpegVideo::AudioRun() {
  std::string err;
  std::unique_ptr<AudioSink> sink = AudioSink::Open(&err);
  if (!sink) {
    dec_->DisableAudio();
    return AudioFail(err);
  }
  std::printf("rn-impeller: video id=%lld audio open %s device=%s\n", (long long)id(),
              dec_->AudioDescription().c_str(), sink->device().c_str());
  std::fflush(stdout);
  {
    std::lock_guard<std::mutex> lock(mu_);
    audio_ = rate_ == 1.0 ? "on" : "muted";
  }
  AudioChunk c;
  bool have = false, flowing = false;
  int off = 0;
  uint64_t gen = 0, seq = 0;
  auto wait = [this](std::unique_lock<std::mutex>& lock, double sec) {
    cv_.wait_for(lock, std::chrono::duration<double>(std::min(std::max(sec, 0.001), kMaxWaitSec)));
  };
  while (true) {
    if (!have) {
      const int r = dec_->DecodeAudio(&c, &err);
      if (r < 0) {
        if (Stopping()) return;
        dec_->DisableAudio();
        return AudioFail(err);
      }
      if (r == kEof) {  // the end: wait for a seek (or a loop) to bring more
        std::unique_lock<std::mutex> lock(mu_);
        const uint64_t seen = seekSeq_;
        cv_.wait(lock, [&] { return stop_ || seekSeq_ != seen; });
        if (stop_) return;
        continue;
      }
      have = true;
      off = 0;
      if (c.gen != gen) {
        if (flowing) sink->Drop();
        flowing = false;
        gen = c.gen;
      }
    }
    double media, rate;
    {
      std::unique_lock<std::mutex> lock(mu_);
      if (stop_) return;
      if (seekSeq_ != seq) {  // a seek landed: what is held is from before it
        seq = seekSeq_;
        have = false;
        continue;
      }
      if (!playing_ || status_ != "readyToPlay" || seekPending_) {
        if (flowing) sink->Drop();  // silence now, not after the device buffer
        flowing = false;
        wait(lock, kMaxWaitSec);
        continue;
      }
      media = MediaNowLocked();
      rate = rate_;
      audio_ = rate == 1.0 ? "on" : "muted";
    }
    const double end = c.pts + (double)c.frames / kAudioRate;
    if (rate != 1.0) {
      if (flowing) sink->Drop();
      flowing = false;
      if (end <= media) {
        have = false;
        continue;
      }
      std::unique_lock<std::mutex> lock(mu_);
      wait(lock, (end - media) / rate);
      continue;
    }
    const double at = c.pts + (double)off / kAudioRate;  // the next sample's media time
    const double diff = at - (media + sink->Delay());     // > 0: it would be heard early
    if (diff < -kSyncTolerance) {
      off += std::min(c.frames - off, (int)std::ceil(-diff * kAudioRate));
      if (off >= c.frames) have = false;
      continue;
    }
    if (diff > kSyncTolerance) {
      std::unique_lock<std::mutex> lock(mu_);
      wait(lock, diff - kSyncTolerance);
      continue;
    }
    const int n = sink->Write(c.pcm.data() + (size_t)off * kAudioChannels,
                              std::min(kWriteFrames, c.frames - off), &err);
    if (n < 0) {
      dec_->DisableAudio();
      return AudioFail(err);
    }
    flowing = true;
    off += n;
    if (off >= c.frames) have = false;
    std::lock_guard<std::mutex> lock(mu_);
    audioFrames_ += (uint64_t)n;
  }
}

}  // namespace rni::ffv
