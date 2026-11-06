// Row 3 video, linux: AudioSink on ALSA (video/AudioSink.h). libasound.so.2 is
// dlopen'd from the host/OptionalLibs table; the handful of entry points are
// declared here (the ALSA ABI has been stable since libasound.so.2), so the
// build needs no ALSA headers.
//
// The PCM is opened NON-blocking. A blocking snd_pcm_writei on a device that
// stopped taking samples sits in the kernel until its DMA timeout (~10 s), and
// the sound thread is joined by release() on the JS thread. Here a write waits
// at most kWaitMs (snd_pcm_wait) and returns, and a device that takes nothing
// for kStallSec is reported as failed.
#include <dlfcn.h>

#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <string>
#include <type_traits>

#include "host/OptionalLibs.h"
#include "video/AudioSink.h"

namespace rni::ffv {
namespace {

struct snd_pcm;
using Pcm = snd_pcm;
// alsa/pcm.h: SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK, SND_PCM_FORMAT_S16_LE,
// SND_PCM_ACCESS_RW_INTERLEAVED.
constexpr int kStreamPlayback = 0;
constexpr int kNonBlock = 1;
constexpr int kFormatS16Le = 2;
constexpr int kAccessRwInterleaved = 3;
// Device buffer: enough to ride out a busy decode thread, small enough that
// pause and seek feel immediate.
constexpr unsigned kLatencyUs = 200000;
constexpr int kWaitMs = 50;

struct Alsa {
  int (*open)(Pcm**, const char*, int, int) = nullptr;
  int (*set_params)(Pcm*, int, int, unsigned, unsigned, int, unsigned) = nullptr;
  long (*writei)(Pcm*, const void*, unsigned long) = nullptr;
  int (*wait)(Pcm*, int) = nullptr;
  int (*recover)(Pcm*, int, int) = nullptr;
  int (*delay)(Pcm*, long*) = nullptr;
  int (*drop)(Pcm*) = nullptr;
  int (*prepare)(Pcm*) = nullptr;
  int (*close)(Pcm*) = nullptr;
  const char* (*strerror)(int) = nullptr;
  std::string error;
};

const Alsa& LoadAlsa() {
  static const Alsa alsa = [] {
    Alsa a;
    const optlib::Opened o = optlib::Open("asound");
    if (!o.handle) {
      a.error = "no ALSA library: " + o.tried + " does not load (" + o.error + ")";
      return a;
    }
    bool ok = true;
    auto sym = [&](auto& fn, const char* name) {
      fn = reinterpret_cast<std::remove_reference_t<decltype(fn)>>(dlsym(o.handle, name));
      if (!fn) ok = false;
    };
    sym(a.open, "snd_pcm_open");
    sym(a.set_params, "snd_pcm_set_params");
    sym(a.writei, "snd_pcm_writei");
    sym(a.wait, "snd_pcm_wait");
    sym(a.recover, "snd_pcm_recover");
    sym(a.delay, "snd_pcm_delay");
    sym(a.drop, "snd_pcm_drop");
    sym(a.prepare, "snd_pcm_prepare");
    sym(a.close, "snd_pcm_close");
    sym(a.strerror, "snd_strerror");
    if (!ok) a.error = o.soname + " lacks a snd_pcm_* entry point";
    return a;
  }();
  return alsa;
}

class AlsaSink final : public AudioSink {
 public:
  using Clock = std::chrono::steady_clock;

  AlsaSink(const Alsa& a, Pcm* pcm, std::string device) : a_(a), pcm_(pcm), device_(std::move(device)) {}
  ~AlsaSink() override {
    a_.drop(pcm_);
    a_.close(pcm_);
  }

  int Write(const int16_t* pcm, int frames, std::string* error) override {
    long n = a_.writei(pcm_, pcm, (unsigned long)frames);
    if (n == -EAGAIN) {  // full: wait for room, briefly
      a_.wait(pcm_, kWaitMs);
      n = a_.writei(pcm_, pcm, (unsigned long)frames);
      if (n == -EAGAIN) n = 0;
    }
    if (n < 0) {
      if (a_.recover(pcm_, (int)n, 1) < 0) {  // underrun / suspend: re-prepared, write again
        *error = "ALSA write on " + device_ + ": " + a_.strerror((int)n);
        return -1;
      }
      n = 0;
    }
    if (n > 0) {
      stalled_ = false;
      return (int)n;
    }
    const Clock::time_point now = Clock::now();
    if (!stalled_) {
      stalled_ = true;
      stallSince_ = now;
    } else if (std::chrono::duration<double>(now - stallSince_).count() >= kStallSec) {
      *error = "ALSA device '" + device_ + "' took no samples for " + std::to_string((int)kStallSec) + " s";
      return -1;
    }
    return 0;
  }

  double Delay() override {
    long d = 0;
    return a_.delay(pcm_, &d) == 0 && d > 0 ? (double)d / kAudioRate : 0;
  }

  void Drop() override {
    a_.drop(pcm_);
    a_.prepare(pcm_);
    stalled_ = false;
  }

  const std::string& device() const override { return device_; }

 private:
  const Alsa& a_;
  Pcm* pcm_;
  const std::string device_;
  bool stalled_ = false;  // the last write took nothing, since stallSince_
  Clock::time_point stallSince_;
};

}  // namespace

std::unique_ptr<AudioSink> AudioSink::Open(std::string* error) {
  const Alsa& a = LoadAlsa();
  if (!a.error.empty()) {
    *error = a.error;
    return nullptr;
  }
  const char* env = std::getenv("RNI_AUDIO_DEVICE");
  const std::string device = env && *env ? env : "default";
  Pcm* pcm = nullptr;
  int r = a.open(&pcm, device.c_str(), kStreamPlayback, kNonBlock);
  if (r < 0) {
    *error = "ALSA device '" + device + "' does not open: " + a.strerror(r);
    return nullptr;
  }
  r = a.set_params(pcm, kFormatS16Le, kAccessRwInterleaved, kAudioChannels, kAudioRate, 1, kLatencyUs);
  if (r < 0) {
    *error = "ALSA device '" + device + "' refuses S16 stereo 48 kHz: " + a.strerror(r);
    a.close(pcm);
    return nullptr;
  }
  return std::make_unique<AlsaSink>(a, pcm, device);
}

}  // namespace rni::ffv
