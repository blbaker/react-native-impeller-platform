// Row 3 video, linux: which ffmpeg copy plays, and the
// backend's public API (video/VideoPlayer.h).
//
// The copies built into this binary come from CMake (RNI_FFMPEG_COPIES; each
// one defines RNI_FFMPEG_COPY_<N>). The selector tries them NEWEST FIRST: 8 is
// what the board image ships, 6 keeps video on ffmpeg 6.1 dev hosts. The first
// copy whose libs load and pass its runtime major check wins, once per process.
// When none does, video is unusable and the error names every copy's reason
// (each missing soname, or the refused majors).
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <string>
#include <vector>

#include "scenegraph/TextureRegistry.h"
#include "video/FfmpegDecoder.h"
#include "video/VideoPlayer.h"

namespace rni {
namespace {

std::vector<const ffv::Copy*> CopiesBuilt() {
  std::vector<const ffv::Copy*> v;
#ifdef RNI_FFMPEG_COPY_8
  v.push_back(&ffv::Ffmpeg8Copy());
#endif
#ifdef RNI_FFMPEG_COPY_6
  v.push_back(&ffv::Ffmpeg6Copy());
#endif
  // Newest release first, whatever order CMake listed them in.
  std::sort(v.begin(), v.end(), [](const ffv::Copy* a, const ffv::Copy* b) { return a->release > b->release; });
  return v;
}

struct Selection {
  const ffv::Copy* copy = nullptr;  // the copy that plays; nullptr = video unusable
  std::string error;
};

const Selection& Select() {
  static const Selection sel = [] {
    Selection s;
    std::string why, tried;
    for (const ffv::Copy* c : CopiesBuilt()) {
      tried += (tried.empty() ? "" : ", ") + std::to_string(c->release);
      std::string e;
      if (c->load(&e)) {
        s.copy = c;
        return s;
      }
      why += (why.empty() ? "" : "; ") + e;
    }
    s.error = tried.empty() ? "no ffmpeg copy compiled in"
                            : "video needs ffmpeg " + tried + " shared libs, tried in that order: " + why;
    return s;
  }();
  return sel;
}

// file:///abs or /abs -> the percent-decoded path; http(s):// -> the URL as is
// (a signed URL's query must reach the server byte for byte); else "".
std::string SourceFromUri(const std::string& uri) {
  if (uri.rfind("http://", 0) == 0 || uri.rfind("https://", 0) == 0) return uri;
  std::string p;
  if (uri.rfind("file://", 0) == 0) {
    p = uri.substr(7);
  } else if (!uri.empty() && uri[0] == '/') {
    p = uri;
  } else {
    return "";
  }
  std::string out;  // percent-decode (file URIs from RN escape spaces etc.)
  for (size_t i = 0; i < p.size(); ++i) {
    if (p[i] == '%' && i + 2 < p.size() && isxdigit((unsigned char)p[i + 1]) &&
        isxdigit((unsigned char)p[i + 2])) {
      out += (char)std::strtol(p.substr(i + 1, 2).c_str(), nullptr, 16);
      i += 2;
    } else {
      out += p[i];
    }
  }
  return out;
}

}  // namespace

bool VideoSupported() { return Select().copy != nullptr; }
const char* VideoBackendName() { return "ffmpeg"; }
std::string VideoLoadError() { return Select().error; }

int VideoFfmpegAbi() {
  if (const ffv::Copy* c = Select().copy) return c->release;
  const auto built = CopiesBuilt();  // none loads: the highest built
  return built.empty() ? 0 : built.front()->release;
}

std::string VideoFfmpegAbisBuilt() {
  std::string s;
  for (const ffv::Copy* c : CopiesBuilt()) s += (s.empty() ? "" : ",") + std::to_string(c->release);
  return s.empty() ? "none" : s;
}

bool VideoLog() {
  static const bool on = [] {
    const char* v = std::getenv("RNI_VIDEO_LOG");
    return v && v[0] == '1';
  }();
  return on;
}

std::shared_ptr<VideoPlayer> CreateVideoPlayer(TextureRegistry* registry, const std::string& uri,
                                               int64_t* textureId, std::string* error) {
  const Selection& sel = Select();
  if (sel.copy == nullptr) {
    *error = sel.error;
    return nullptr;
  }
  const std::string source = SourceFromUri(uri);
  if (source.empty()) {
    *error = "video: unsupported source (file://, an absolute path, http:// or https://): " +
             ffv::RedactUri(uri);
    return nullptr;
  }
  const int64_t id = registry->NextId();
  *textureId = id;
  return ffv::StartPlayer(registry, id, source, *sel.copy);
}

namespace ffv {

std::string RedactUri(const std::string& uri) {
  const size_t scheme = uri.find("://");
  if (scheme == std::string::npos) return uri;  // a path
  std::string out = uri;
  const size_t q = out.find_first_of("?#", scheme + 3);
  if (q != std::string::npos && out[q] == '?') out = out.substr(0, q) + "?<redacted>";
  const size_t hostEnd = out.find_first_of("/?#", scheme + 3);
  const size_t at = out.rfind('@', hostEnd == std::string::npos ? out.size() : hostEnd);
  if (at != std::string::npos && at > scheme) out = out.substr(0, scheme + 3) + "<redacted>@" + out.substr(at + 1);
  return out;
}

}  // namespace ffv

}  // namespace rni
