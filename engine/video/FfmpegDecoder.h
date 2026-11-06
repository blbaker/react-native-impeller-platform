// Row 3 video, linux: the seam between the ffmpeg-free player and the ffmpeg
// copies.
//
// The engine dlopens ffmpeg, and the decode code reads AVFrame/AVCodecContext
// fields directly, so it is only safe against the ABI of the headers it was
// compiled with. engine/video/FfmpegCopy.cpp is therefore compiled ONCE PER
// ffmpeg release that has headers (CMake RNI_FFMPEG_COPIES: 8 = the board
// image's 8.0.1, required on linux; 6 = 6.1 dev hosts), each copy in its own
// namespace. Everything in this header is ffmpeg-free, and so are the player
// (FfmpegPlayer.h + VideoPlayerFfmpeg.cpp) and the selector (FfmpegSelect.cpp):
//
//   selector: try the copies newest first; the first whose four libs dlopen AND
//             whose loaded majors equal its compiled majors wins. A copy whose
//             libs load but report other majors is REFUSED, never used.
//   player:   media clock, decode thread, seek; asks its Decoder for frames.
//
// ⛔ No template over an ffmpeg type may cross a copy boundary: two copies see
// two different `struct AVFrame`, and a COMDAT instantiation would be shared.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "video/AudioSink.h"
#include "video/VideoPlayer.h"

namespace rni {
class TextureRegistry;
}

namespace rni::ffv {

struct StreamInfo {
  int width = 0, height = 0;
  double duration = 0;          // seconds; 0 = unknown
  double frameDur = 1.0 / 30;   // seconds per frame (avg_frame_rate, else r_frame_rate)
  std::string codec;            // decoder name, e.g. "h264", or "h264_rkmpp" on the VPU
  bool hw = false;              // a hardware decoder opened (video/FfmpegCopyHw.h)
  std::string hwOff;            // when !hw: why not, e.g. "RNI_VIDEO_HW=0"
};

// The two frame slots the player juggles: NEXT = decoded, not yet shown;
// TMP = scratch for look-ahead while catching up or seeking.
enum Slot : int { kNext = 0, kTmp = 1 };
constexpr int kEof = 1;  // DecodeNext: 0 = a frame, kEof = end of stream, < 0 = error

// Decoded sound in the sink's format: S16 interleaved, kAudioChannels, kAudioRate.
struct AudioChunk {
  std::vector<int16_t> pcm;  // frames * kAudioChannels samples
  int frames = 0;
  double pts = 0;    // seconds, on the video pts' zero
  uint64_t gen = 0;  // the input's seek generation it was read in
};

class Decoder {
 public:
  virtual ~Decoder() = default;
  // `source`: a local path, or an http:// / https:// URL (video/FfmpegCopyInput.h).
  virtual bool Open(const std::string& source, StreamInfo* info, std::string* error) = 0;
  // Decodes the next frame of the video stream into `slot`; *pts in seconds
  // from the stream start.
  virtual int DecodeNext(Slot slot, double* pts, std::string* error) = 0;
  virtual void Swap() = 0;  // NEXT <- TMP, TMP emptied
  // Seek to the keyframe at or before `target` seconds and flush the decoder.
  virtual bool SeekBackward(double target, std::string* error) = 0;
  // `slot` as opaque RGBA8 (alpha 255), width * height * 4 bytes.
  virtual bool ToRgba(Slot slot, std::vector<uint8_t>* rgba, int* width, int* height,
                      std::string* error) = 0;
  // Any thread: unblock a network read; the decoder fails every call after.
  virtual void Abort() = 0;
  // Seconds DecodeNext spent waiting for input (network) since the last call.
  virtual double TakeWaited() = 0;

  // Sound (video/FfmpegCopyAudio.h), after Open. "" = there is sound to play,
  // else why not ("no audio stream", a missing libswresample, ...).
  virtual std::string AudioUnavailable() = 0;
  virtual std::string AudioDescription() = 0;  // "aac 44100 Hz 2 ch"
  // The audio thread only. 0 = *out filled, kEof = end of input (until a
  // seek), < 0 = failed (*error).
  virtual int DecodeAudio(AudioChunk* out, std::string* error) = 0;
  virtual void DisableAudio() = 0;  // no sink: stop reading the audio stream
};

// `uri` with its query string and user info replaced by "<redacted>", for
// logs and error strings: a signed URL's query is a credential.
std::string RedactUri(const std::string& uri);

struct Copy {
  int release;      // the ffmpeg release whose headers this copy was compiled against
  int majors[4];    // compiled LIB{AVUTIL,AVCODEC,AVFORMAT,SWSCALE}_VERSION_MAJOR
  // dlopen the release's soname set (host/OptionalLibs) and check the loaded
  // majors; cached after the first call. false + *error = this copy can't run.
  bool (*load)(std::string* error);
  std::unique_ptr<Decoder> (*create)();
};

// One per compiled copy (FfmpegCopy.cpp with RNI_FF_RELEASE=8 / 6).
const Copy& Ffmpeg8Copy();
const Copy& Ffmpeg6Copy();

// VideoPlayerFfmpeg.cpp: the player on a decoder from `copy`, registered in
// `registry` under `id`, decode thread started.
std::shared_ptr<VideoPlayer> StartPlayer(TextureRegistry* registry, int64_t id, std::string path,
                                         const Copy& copy);

}  // namespace rni::ffv
