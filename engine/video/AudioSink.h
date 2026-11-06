// Row 3 video, linux: sound output for the ffmpeg player (ALSA, dlopen'd
// through host/OptionalLibs "asound", so the engine starts without it).
// Fixed format: S16 interleaved stereo at 48 kHz; the decoder side resamples
// to it (video/FfmpegCopyAudio.h). Device: RNI_AUDIO_DEVICE, else "default".
#pragma once

#include <cstdint>
#include <memory>
#include <string>

namespace rni::ffv {

constexpr int kAudioRate = 48000;
constexpr int kAudioChannels = 2;
constexpr double kStallSec = 4;  // a device that takes no samples this long has failed

class AudioSink {
 public:
  // nullptr + *error when libasound is missing or the device does not open.
  static std::unique_ptr<AudioSink> Open(std::string* error);
  virtual ~AudioSink() = default;
  // Writes what fits, waiting at most ~50 ms for room, so the caller can see a
  // stop or a pause in time (a device that stops taking samples must not hold
  // release() up). Returns the frames written (0 = no room yet), or -1 +
  // *error when the device failed, including when it took nothing for
  // kStallSec while being written.
  virtual int Write(const int16_t* pcm, int frames, std::string* error) = 0;
  virtual double Delay() = 0;  // seconds queued ahead of the speaker (0 if unknown)
  virtual void Drop() = 0;     // discard what is queued, ready for new samples
  virtual const std::string& device() const = 0;
};

}  // namespace rni::ffv
