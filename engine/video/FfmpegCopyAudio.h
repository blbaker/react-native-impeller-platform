// Row 3 video, linux: the sound side of ONE ffmpeg copy (see
// video/FfmpegCopyAv.h for how a copy is compiled). AudioDec decodes the
// Input's audio stream and resamples it to the sink format (S16 interleaved
// stereo, kAudioRate) with libswresample. Used only by the player's audio
// thread, through the copy's Decoder (video/FfmpegDecoder.h).
#pragma once

#include <cstdint>
#include <string>

#include "video/FfmpegCopyAv.h"
#include "video/FfmpegCopyInput.h"
#include "video/FfmpegDecoder.h"

namespace rni::ffv::RNI_FF_NS {

// dlopens this release's libswresample (host/OptionalLibs) into *av and checks
// its major. "" = sound can be decoded, else why not.
std::string LoadSwr(Av* av);

class AudioDec {
 public:
  AudioDec(const Av& av, Input& in) : av_(av), in_(in) {}
  ~AudioDec();
  // Opens the decoder for in.audioStream(). `originSec` = the video stream's
  // start, so audio and video pts share one zero. "" = ready, else why not.
  std::string Open(double originSec);
  std::string Describe() const;  // "aac 44100 Hz 2 ch"
  // 0 = *out filled, kEof = end of input (until a seek), < 0 = failed.
  int Decode(AudioChunk* out, std::string* error);

 private:
  bool Convert(AudioChunk* out, std::string* error);
  void Flush();  // a seek happened: drop the decoder's and the resampler's state

  const Av& av_;
  Input& in_;
  AVCodecContext* ctx_ = nullptr;
  AVFrame* f_ = nullptr;
#if RNI_FF_HAS_SWR
  SwrContext* swr_ = nullptr;
#endif
  int swrFormat_ = -1, swrRate_ = 0, swrChannels_ = 0;
  double tb_ = 0, origin_ = 0, nextPts_ = 0;
  uint64_t gen_ = 0;
  bool draining_ = false, eof_ = false;
};

}  // namespace rni::ffv::RNI_FF_NS
