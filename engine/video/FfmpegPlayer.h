// Row 3 video, linux backend: the player class (split it from the
// ffmpeg code). No ffmpeg headers: it drives a Decoder from whichever ffmpeg
// copy video/FfmpegSelect.cpp picked (video/FfmpegDecoder.h). Included only by
// video/VideoPlayerFfmpeg.cpp, which holds the decode thread (Open/Step/DoSeek).
//
// One decode thread per player, plus a sound thread when the source has audio
// and a device opens (video/VideoPlayerAudio.cpp: it follows the same clock,
// muted when the rate is not 1). Media clock: anchorMedia_ + (wall - anchorWall_)
// * rate_ while playing. The thread publishes the latest frame whose pts the
// clock has reached; frames the clock already passed are decoded but not
// converted (framesDropped). Seek decodes from the previous keyframe to the
// target and shows that frame even while paused.
#pragma once

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>

#include "base/MemTrim.h"
#include "scenegraph/FrameRecycler.h"
#include "scenegraph/TextureRegistry.h"
#include "video/FfmpegDecoder.h"
#include "video/VideoPlayer.h"

namespace rni::ffv {

class FfmpegVideo final : public ExternalTexture, public VideoPlayer {
 public:
  using Clock = std::chrono::steady_clock;

  FfmpegVideo(TextureRegistry* registry, int64_t id, std::string path, const Copy& copy)
      : ExternalTexture(id), dec_(copy.create()), release_(copy.release), registry_(registry),
        path_(std::move(path)) {}
  ~FfmpegVideo() override {
    Stop();
    std::printf("rn-impeller: video id=%lld destroyed frame_buffers=%llu frames_shown=%llu\n", (long long)id(),
                (unsigned long long)frames_->allocated(), (unsigned long long)framesShown_);
    std::fflush(stdout);
    memtrim::Request("video");  // the decoder, its threads' buffers and the frames go now
  }

  void Start() {
    thread_ = std::thread([this] { Run(); });
  }

  std::shared_ptr<const ExternalFrame> CopyFrame() override {
    std::lock_guard<std::mutex> lock(mu_);
    return latest_;
  }

  void OnUnregistered() override { Stop(); }

  void Play() override {
    std::lock_guard<std::mutex> lock(mu_);
    if (ended_) {  // HTMLMediaElement / expo-video: play() at the end restarts
      ended_ = false;
      seekPending_ = true;
      seekTarget_ = 0;
      anchorMedia_ = 0;
    } else {
      anchorMedia_ = MediaNowLocked();
    }
    anchorWall_ = Clock::now();
    playing_ = true;
    cv_.notify_all();
  }

  void Pause() override {
    std::lock_guard<std::mutex> lock(mu_);
    anchorMedia_ = MediaNowLocked();
    anchorWall_ = Clock::now();
    playing_ = false;
    cv_.notify_all();
  }

  void Seek(double seconds) override {
    std::lock_guard<std::mutex> lock(mu_);
    double t = std::max(0.0, seconds);
    if (duration_ > 0) t = std::min(t, duration_);
    seekTarget_ = t;
    seekPending_ = true;
    anchorMedia_ = t;
    anchorWall_ = Clock::now();
    ended_ = false;
    cv_.notify_all();
  }

  void SetRate(double rate) override {
    std::lock_guard<std::mutex> lock(mu_);
    anchorMedia_ = MediaNowLocked();
    anchorWall_ = Clock::now();
    rate_ = std::min(16.0, std::max(1.0 / 16.0, std::isfinite(rate) ? rate : 1.0));
    cv_.notify_all();
  }

  void SetLoop(bool loop) override {
    std::lock_guard<std::mutex> lock(mu_);
    loop_ = loop;
  }

  VideoStatus Status() override {
    std::lock_guard<std::mutex> lock(mu_);
    VideoStatus s;
    s.status = status_;
    s.error = error_;
    s.duration = duration_;
    double t = MediaNowLocked();
    if (duration_ > 0) t = std::min(t, duration_);
    s.currentTime = std::max(0.0, t);
    s.rate = rate_;
    s.playing = playing_;
    s.loop = loop_;
    s.ended = ended_;
    s.width = width_;
    s.height = height_;
    s.framesShown = framesShown_;
    s.framesDropped = framesDropped_;
    s.audio = audio_;
    s.audioFrames = audioFrames_;
    return s;
  }

 private:
  double MediaNowLocked() const {
    if (!playing_) return anchorMedia_;
    return anchorMedia_ + std::chrono::duration<double>(Clock::now() - anchorWall_).count() * rate_;
  }

  // The clock starts at the first frame on screen and restarts at a seek's
  // frame, and time spent waiting on network input does not advance it.
  // Otherwise a slow open, seek or stall comes back as a burst of dropped frames.
  void ReanchorLocked(double media) {
    anchorMedia_ = media;
    anchorWall_ = Clock::now();
  }
  void CreditWaited() {
    const double w = dec_->TakeWaited();
    if (w <= 0 || !firstShown_) return;
    std::lock_guard<std::mutex> lock(mu_);
    if (playing_) anchorWall_ += std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(w));
  }

  void Stop() {
    {
      std::lock_guard<std::mutex> lock(mu_);
      stop_ = true;
    }
    dec_->Abort();  // a read blocked on the network returns now
    cv_.notify_all();
    if (thread_.joinable() && thread_.get_id() != std::this_thread::get_id()) thread_.join();
    // Started by the decode thread, so it is set (or not) once thread_ is joined.
    if (audioThread_.joinable() && audioThread_.get_id() != std::this_thread::get_id()) audioThread_.join();
  }
  bool Stopping() {
    std::lock_guard<std::mutex> lock(mu_);
    return stop_;
  }

  // The decode thread (video/VideoPlayerFfmpeg.cpp).
  bool Fail(const std::string& what);
  bool Open();
  int Decode(Slot slot, double* pts);  // 0 = a frame, kEof; < 0 = failed the player
  bool Publish(Slot slot, double pts);
  bool DoSeek(double target);
  bool Step();   // one turn of the decode loop; false = the thread exits
  bool AtEnd();  // no frame left: loop, or mark ended and wait for a seek
  void Run();
  void StartAudio();  // decode thread, after Open
  void AudioRun();    // the sound thread (video/VideoPlayerAudio.cpp)
  void AudioFail(const std::string& why);

  const std::unique_ptr<Decoder> dec_;
  const int release_;
  TextureRegistry* registry_;
  const std::string path_;
  const std::shared_ptr<FrameRecycler> frames_ = FrameRecycler::Make();  // Publish's RGBA buffers
  std::thread thread_, audioThread_;

  // Decode-thread state (no lock).
  double frameDur_ = 1.0 / 30, lastPts_ = 0, nextPts_ = 0;
  bool haveNext_ = false, eof_ = false, firstShown_ = false;

  // Shared (mu_).
  std::mutex mu_;
  std::condition_variable cv_;
  bool stop_ = false;
  std::string status_ = "loading", error_;
  std::shared_ptr<const ExternalFrame> latest_;
  uint64_t seq_ = 0, framesShown_ = 0, framesDropped_ = 0;
  int width_ = 0, height_ = 0;
  double duration_ = 0;
  bool playing_ = false, loop_ = false, ended_ = false, seekPending_ = false;
  double seekTarget_ = 0, rate_ = 1, anchorMedia_ = 0;
  std::string audio_ = "none";
  uint64_t audioFrames_ = 0;
  uint64_t seekSeq_ = 0;  // bumped when a seek's frame is up: the sound thread resyncs
  Clock::time_point anchorWall_ = Clock::now();
};

}  // namespace rni::ffv
