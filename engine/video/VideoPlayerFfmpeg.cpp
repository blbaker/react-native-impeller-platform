// Row 3 video, linux backend: the player's decode thread (video/FfmpegPlayer.h
// has the class, its media clock and the JS-facing controls). No ffmpeg
// headers here either: frames come from the copy's Decoder.
#include <cstdio>

#include "video/FfmpegPlayer.h"

namespace rni::ffv {
namespace {

long long NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

}  // namespace

bool FfmpegVideo::Fail(const std::string& what) {
  std::lock_guard<std::mutex> lock(mu_);
  status_ = "error";
  error_ = what;
  playing_ = false;
  std::fprintf(stderr, "rn-impeller: video id=%lld error %s\n", (long long)id(), error_.c_str());
  return false;
}

bool FfmpegVideo::Open() {
  StreamInfo info;
  std::string err;
  const bool network = path_.rfind("http://", 0) == 0 || path_.rfind("https://", 0) == 0;
  if (network) {
    std::printf("rn-impeller: video id=%lld source %s\n", (long long)id(), RedactUri(path_).c_str());
    std::fflush(stdout);
  }
  if (!dec_->Open(path_, &info, &err)) return Stopping() ? false : Fail(err);
  frameDur_ = info.frameDur;
  std::lock_guard<std::mutex> lock(mu_);
  duration_ = info.duration;
  width_ = info.width;
  height_ = info.height;
  // ffmpeg_abi = the copy decoding this file (ci-video-ffmpeg8.sh reads it).
  std::printf("rn-impeller: video id=%lld open %dx%d codec=%s duration=%.3f fps=%.3f backend=ffmpeg ffmpeg_abi=%d\n",
              (long long)id(), width_, height_, info.codec.c_str(), duration_, 1.0 / frameDur_, release_);
  // One line per stream, so a check can tell the VPU from the CPU decoder.
  std::printf("rn-impeller: VIDEO_DECODER source=%lld codec=%s hw=%d convert=sws\n", (long long)id(),
              info.codec.c_str(), info.hw ? 1 : 0);
  if (!info.hw) std::printf("rn-impeller: video id=%lld hw decode off: %s\n", (long long)id(), info.hwOff.c_str());
  std::fflush(stdout);
  return true;
}

int FfmpegVideo::Decode(Slot slot, double* pts) {
  std::string err;
  const int r = dec_->DecodeNext(slot, pts, &err);
  if (r == 0) lastPts_ = *pts;
  if (r < 0 && !Stopping()) Fail(err);  // released mid-read: the abort is not an error
  return r;
}

bool FfmpegVideo::Publish(Slot slot, double pts) {
  std::shared_ptr<ExternalFrame> ef = frames_->Take();
  std::string err;
  if (!dec_->ToRgba(slot, &ef->rgba, &ef->width, &ef->height, &err)) return Fail(err);
  uint64_t seq;
  {
    std::lock_guard<std::mutex> lock(mu_);
    width_ = ef->width;
    height_ = ef->height;
    seq = ef->seq = ++seq_;
    latest_ = std::move(ef);
    ++framesShown_;
    if (status_ == "loading") status_ = "readyToPlay";
  }
  if (VideoLog()) {
    std::printf("rn-impeller: video_frame id=%lld seq=%llu pts=%.3f t_us=%lld\n", (long long)id(),
                (unsigned long long)seq, pts, NowUs());
    std::fflush(stdout);
  }
  registry_->MarkFrameAvailable(id());
  return true;
}

// Decode from the keyframe before `target`; show the last frame at or before it.
bool FfmpegVideo::DoSeek(double target) {
  std::string err;
  if (!dec_->SeekBackward(target, &err)) return Fail(err);
  eof_ = false;
  haveNext_ = false;
  bool have = false, haveTmp = false;
  double p = 0, shownPts = 0;
  while (true) {
    const int r = Decode(kTmp, &p);
    if (r == kEof) {
      eof_ = true;
      break;
    }
    if (r < 0) return false;
    if (!have || p <= target + 1e-4) {
      dec_->Swap();
      shownPts = p;
      have = true;
      if (p > target + 1e-4) break;  // nothing at/before target: the first frame after it
      continue;
    }
    haveTmp = true;  // the frame after the target
    break;
  }
  if (have && !Publish(kNext, shownPts)) return false;
  if (haveTmp) {
    dec_->Swap();
    nextPts_ = p;
    haveNext_ = true;
  }
  firstShown_ = have;
  dec_->TakeWaited();  // the seek's own read time is not a stall
  std::lock_guard<std::mutex> lock(mu_);
  if (!seekPending_) ReanchorLocked(target);
  ++seekSeq_;
  cv_.notify_all();
  std::printf("rn-impeller: video id=%lld seek target=%.3f shown_pts=%.3f\n", (long long)id(), target,
              shownPts);
  std::fflush(stdout);
  return true;
}

bool FfmpegVideo::Step() {
  bool doSeek = false;
  double target = 0;
  {
    std::lock_guard<std::mutex> lock(mu_);
    if (stop_) return false;
    if (seekPending_) {
      doSeek = true;
      target = seekTarget_;
      seekPending_ = false;
    }
  }
  if (doSeek) return DoSeek(target);
  if (!haveNext_ && !eof_) {
    const int r = Decode(kNext, &nextPts_);
    if (r < 0) return false;
    if (r == 0) haveNext_ = true;
    else eof_ = true;
  }
  if (!haveNext_ && eof_) return AtEnd();
  CreditWaited();
  double media;
  {
    std::lock_guard<std::mutex> lock(mu_);
    media = MediaNowLocked();
  }
  if (!firstShown_ || nextPts_ <= media) {
    // Catch up: skip (decode, don't convert) frames the clock is already past.
    bool haveTmp = false;
    double p = 0;
    while (firstShown_) {
      const int r = Decode(kTmp, &p);
      if (r == kEof) {
        eof_ = true;
        break;
      }
      if (r < 0) return false;
      if (p <= media) {
        dec_->Swap();
        nextPts_ = p;
        std::lock_guard<std::mutex> lock(mu_);
        ++framesDropped_;
        continue;
      }
      haveTmp = true;
      break;
    }
    if (!Publish(kNext, nextPts_)) return false;
    if (!firstShown_) {
      dec_->TakeWaited();  // the open's read time is not a stall
      std::lock_guard<std::mutex> lock(mu_);
      if (!seekPending_) ReanchorLocked(nextPts_);
    }
    firstShown_ = true;
    if (haveTmp) {
      dec_->Swap();
      nextPts_ = p;
    }
    haveNext_ = haveTmp;
    return true;
  }
  std::unique_lock<std::mutex> lock(mu_);
  if (stop_ || seekPending_) return true;
  if (!playing_) {
    cv_.wait(lock, [this] { return stop_ || seekPending_ || playing_; });
    return true;
  }
  const double wait = (nextPts_ - MediaNowLocked()) / rate_;
  if (wait > 0) cv_.wait_for(lock, std::chrono::duration<double>(std::min(wait, 0.1)));
  return true;
}

bool FfmpegVideo::AtEnd() {
  std::unique_lock<std::mutex> lock(mu_);
  if (loop_) {
    seekPending_ = true;
    seekTarget_ = 0;
    anchorMedia_ = 0;
    anchorWall_ = Clock::now();
    return true;
  }
  if (!ended_) {
    ended_ = true;
    playing_ = false;
    anchorMedia_ = duration_ > 0 ? duration_ : lastPts_ + frameDur_;
    std::printf("rn-impeller: video id=%lld ended frames_shown=%llu dropped=%llu\n", (long long)id(),
                (unsigned long long)framesShown_, (unsigned long long)framesDropped_);
    std::fflush(stdout);
  }
  cv_.wait(lock, [this] { return stop_ || seekPending_; });
  return true;
}

void FfmpegVideo::Run() {
  if (!Open()) return;
  StartAudio();
  while (Step()) {
  }
}

std::shared_ptr<VideoPlayer> StartPlayer(TextureRegistry* registry, int64_t id, std::string path,
                                         const Copy& copy) {
  auto v = std::make_shared<FfmpegVideo>(registry, id, std::move(path), copy);
  registry->Register(v);
  v->Start();
  return v;
}

}  // namespace rni::ffv
