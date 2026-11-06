// Row 3 video: builds with no video backend (a platform whose backend is not
// written yet; on linux the ffmpeg 8 copy is required, so a linux configure
// without its headers fails instead of landing here). Every create fails
// with this message; ImpellerVideo.isSupported() is false.
#include "video/VideoPlayer.h"

namespace rni {

bool VideoSupported() { return false; }
const char* VideoBackendName() { return "none"; }
int VideoFfmpegAbi() { return 0; }
std::string VideoFfmpegAbisBuilt() { return "none"; }
std::string VideoLoadError() { return "no video backend compiled in"; }
bool VideoLog() { return false; }

std::shared_ptr<VideoPlayer> CreateVideoPlayer(TextureRegistry*, const std::string&, int64_t*,
                                               std::string* error) {
  *error = "video is not supported by this engine build (no video backend compiled in)";
  return nullptr;
}

}  // namespace rni
