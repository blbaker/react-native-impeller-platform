// Row 3 video, linux: the ffmpeg function table of ONE copy (see
// video/FfmpegDecoder.h). Included only by the per-copy sources
// (video/FfmpegCopy.cpp, video/FfmpegCopyInput.cpp), which CMake compiles once
// per ffmpeg release with RNI_FF_RELEASE=<n> and that release's headers. Every
// name here lives in rni::ffv::copy<N>, so two copies never share a symbol that
// names an ffmpeg type.
#pragma once

#include <string>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/dict.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/log.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
}
// Sound needs libswresample. The ffmpeg 6 dev headers have none, so that copy
// plays video without sound.
#if __has_include(<libswresample/swresample.h>)
#define RNI_FF_HAS_SWR 1
extern "C" {
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>
}
#else
#define RNI_FF_HAS_SWR 0
#endif

#ifndef RNI_FF_RELEASE
#error "RNI_FF_RELEASE (8 or 6) is set by engine/CMakeLists.txt"
#endif
#define RNI_FF_CAT2(a, b) a##b
#define RNI_FF_CAT(a, b) RNI_FF_CAT2(a, b)
#define RNI_FF_NS RNI_FF_CAT(copy, RNI_FF_RELEASE)
#define RNI_FF_ENTRY RNI_FF_CAT(RNI_FF_CAT(Ffmpeg, RNI_FF_RELEASE), Copy)

namespace rni::ffv::RNI_FF_NS {

#define RNI_AV_FUNCS(X)                                                                     \
  X(fmt, avformat_open_input) X(fmt, avformat_find_stream_info) X(fmt, av_find_best_stream) \
  X(fmt, av_read_frame) X(fmt, av_seek_frame) X(fmt, avformat_close_input)                  \
  X(fmt, avformat_alloc_context)                                                            \
  X(codec, avcodec_alloc_context3) X(codec, avcodec_parameters_to_context)                  \
  X(codec, avcodec_open2) X(codec, avcodec_send_packet) X(codec, avcodec_receive_frame)     \
  X(codec, avcodec_flush_buffers) X(codec, avcodec_free_context) X(codec, av_packet_alloc)  \
  X(codec, av_packet_free) X(codec, av_packet_unref) X(util, av_frame_alloc)                \
  X(util, av_frame_free) X(util, av_frame_unref) X(util, av_frame_move_ref)                 \
  X(util, av_strerror) X(util, av_dict_set) X(util, av_dict_get) X(util, av_dict_free)      \
  X(util, av_log_set_level) X(util, av_channel_layout_default)                              \
  X(codec, avcodec_find_decoder_by_name) X(util, av_hwframe_transfer_data)                  \
  X(util, av_frame_get_buffer) X(util, av_get_pix_fmt_name)                                 \
  X(sws, sws_getCachedContext) X(sws, sws_scale)                                            \
  X(sws, sws_freeContext) X(sws, sws_getCoefficients) X(sws, sws_setColorspaceDetails)      \
  X(util, avutil_version) X(codec, avcodec_version) X(fmt, avformat_version) X(sws, swscale_version)

// libswresample, loaded on its own (host/OptionalLibs SwresampleForRelease):
// without it the copy still plays video.
#define RNI_SWR_FUNCS(X)                                                        \
  X(swr_alloc_set_opts2) X(swr_init) X(swr_convert) X(swr_free) X(swr_get_out_samples) \
  X(swresample_version)

struct Av {
#define RNI_AV_PTR(lib, fn) decltype(&::fn) fn = nullptr;
  RNI_AV_FUNCS(RNI_AV_PTR)
#undef RNI_AV_PTR
#if RNI_FF_HAS_SWR
#define RNI_SWR_PTR(fn) decltype(&::fn) fn = nullptr;
  RNI_SWR_FUNCS(RNI_SWR_PTR)
#undef RNI_SWR_PTR
#endif
  bool ok = false;
  std::string error;
  std::string swrError;  // "" = sound can be decoded
};

// "<what>: <av_strerror(err)>" (just <what> when err >= 0).
inline std::string AvError(const Av& av, const std::string& what, int err) {
  char buf[128] = {0};
  if (err < 0) av.av_strerror(err, buf, sizeof buf);
  return what + (buf[0] ? std::string(": ") + buf : std::string());
}

}  // namespace rni::ffv::RNI_FF_NS
