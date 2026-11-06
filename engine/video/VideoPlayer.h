// Row 3: a video player that paints through the FP-42
// external-texture path. The player is an ExternalTexture producer: it decodes
// on its own thread, keeps a media clock (play / pause / seek / playbackRate /
// loop) and publishes the frame whose pts the clock has reached as premultiplied
// RGBA. <ImpellerTextureView textureId> paints it (GL and Metal alike).
//
// Backends: linux = ffmpeg (libavformat/libavcodec/libswscale, dlopen'd from
// the system at first use; one copy of the decoder per ffmpeg release it was
// compiled against, newest first: video/FfmpegDecoder.h). Builds without a
// backend get VideoSupported() == false and CreateVideoPlayer fails with a message.
#pragma once

#include <cstdint>
#include <memory>
#include <string>

namespace rni {

class TextureRegistry;

struct VideoStatus {
  // "loading" until the first frame is decoded, then "readyToPlay"; "error" on failure.
  std::string status = "loading";
  std::string error;
  double duration = 0;     // seconds; 0 until known
  double currentTime = 0;  // seconds, the media clock (clamped to [0, duration])
  double rate = 1;
  bool playing = false;
  bool loop = false;
  bool ended = false;      // reached the end with loop off
  int width = 0, height = 0;
  uint64_t framesShown = 0;    // frames published to the texture
  uint64_t framesDropped = 0;  // decoded but skipped because the clock was past them
  // Sound: "none" (no audio stream, or not open yet), "on", "muted" (rate is
  // not 1: there is no pitch-keeping time stretch), "error: <why>".
  std::string audio = "none";
  uint64_t audioFrames = 0;    // 48 kHz frames written to the sound device
};

class VideoPlayer {
 public:
  virtual ~VideoPlayer() = default;
  virtual void Play() = 0;
  virtual void Pause() = 0;
  virtual void Seek(double seconds) = 0;    // also while paused: the target frame is shown
  virtual void SetRate(double rate) = 0;    // clamped to [1/16, 16]
  virtual void SetLoop(bool loop) = 0;
  virtual VideoStatus Status() = 0;
};

bool VideoSupported();
const char* VideoBackendName();  // "ffmpeg", "none"
// For `rn-impeller --doctor`:
// - the ffmpeg release of the copy that will play video; when no copy loads,
//   the highest release built (0 = no ffmpeg backend in this build)
// - every release built, newest first ("8,6"; "none")
// - why video cannot run ("" = it can): each copy's missing sonames or refusal
int VideoFfmpegAbi();
std::string VideoFfmpegAbisBuilt();
std::string VideoLoadError();

// Opens `uri` (file:///abs/path, /abs/path, or an http:// / https:// URL: MP4
// or HLS, docs/eng/video-net.md) on a new decode thread and
// registers the player's texture in `registry` under a fresh id. Returns null
// and sets *error when the backend is missing or the uri is not supported.
// Open and decode errors after creation surface as Status().status == "error".
std::shared_ptr<VideoPlayer> CreateVideoPlayer(TextureRegistry* registry, const std::string& uri,
                                               int64_t* textureId, std::string* error);

bool VideoLog();  // RNI_VIDEO_LOG=1: one `video_frame id= seq= pts=` line per published frame

}  // namespace rni
