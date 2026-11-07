// Every optional shared library the linux engine dlopens, in ONE table
// (linux matrix M2).
//
// The engine links no X11, fontconfig, gbm or ffmpeg by name: the linux
// packages must start on the board image (Wayland only, no libX11, ffmpeg 8)
// and on a desktop alike. Each of those libraries is dlopen'd at first use from
// a soname fallback list, and the list lives HERE, not at the call site:
//
//   host/X11Dl.h               libX11   (platform views, RNI_X11_DLOPEN)
//   host/PlatformViewsX11Gl    libXext  (XShapeCombineRectangles)
//   text/FontFallback+Family   fontconfig
//   host/HeadlessEglRungs      libgbm   (the GBM headless EGL rung)
//   video/FfmpegCopy           ffmpeg   (each copy opens the set of the release
//                                        it was compiled for; FfmpegSets below,
//                                        plus that release's libswresample)
//   video/AudioSinkAlsa        libasound (video sound)
//
// `rn-impeller --doctor` reports from the same table through the same Open(),
// so it cannot claim a library the engine itself would fail to load. A wrong
// list breaks the loader AND shows up in the doctor (tools/ci-doctor.sh,
// mutant M1 in tools/mutation-verify-doctor.sh).
#pragma once

#include <cstddef>
#include <string>

namespace rni::optlib {

struct Lib {
  const char* key;          // doctor key: dlopen.<key>.*
  const char* use;          // what the engine loses without it
  const char* sonames[4];   // tried in order; nullptr-terminated
};

// All single-library entries, in doctor order.
const Lib* All(size_t* count);
const Lib* Find(const char* key);

struct Opened {
  void* handle = nullptr;   // nullptr = none of the sonames loaded
  std::string soname;       // the one that loaded
  std::string tried;        // comma-separated list, in order
  std::string error;        // dlerror() of the LAST failed attempt
};

// dlopen(RTLD_NOW | RTLD_LOCAL) each soname of `key` in order; first wins.
// Handles are never closed (dlopen refcounts, so repeated calls are cheap and
// return the same handle). Unknown key = nothing opened, error says so.
Opened Open(const char* key);

// ffmpeg is a SET of four libraries per major release, and a decoder copy can
// only use the set whose ABI its headers match (it reads AVFrame /
// AVCodecContext fields directly). The video backend has one copy per release
// it was compiled against (video/FfmpegCopy.cpp) and opens that release's set
// from here; the doctor tries every set, newest first.
struct FfmpegSet {
  int release;              // 8, 7, 6
  int avcodecMajor;         // LIBAVCODEC_VERSION_MAJOR of that release
  const char* sonames[4];   // avutil, avcodec, avformat, swscale
};
const FfmpegSet* FfmpegSets(size_t* count);
const FfmpegSet* FfmpegSetForRelease(int release);
// The release's libswresample soname (video sound: audio decode output goes
// through it). Not part of FfmpegSet: video plays without it. nullptr = unknown.
const char* SwresampleForRelease(int release);

}  // namespace rni::optlib
