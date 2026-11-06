// Row 3 video, linux: which decoder opens the video stream, and copying a
// hardware frame out for the CPU converter. Compiled once
// per ffmpeg copy with FfmpegCopy.cpp (video/FfmpegCopyAv.h).
//
// An RK3588 board image runs ffmpeg 8.0.1 with h264_rkmpp, hevc_rkmpp
// and vp9_rkmpp, which decode on the VPU through /dev/mpp_service. ffmpeg lists
// its software decoder first for each codec (n8.0.1 allcodecs.c:152 h264,
// :158 h264_rkmpp), so av_find_best_stream never returns rkmpp: it is asked for
// by name, and used only when
// - RNI_VIDEO_HW is not "0" (RNI_VIDEO_HW=0 forces software, for A/B runs);
// - the stream is 8-bit 4:2:0. rkmppdec hands out NV12 only: every other MPP
//   format gets sw_format NONE (rkmppdec.c:360), so its frames could not be
//   copied out, and a 10-bit or 4:2:2 file that plays in software would fail;
// - avcodec_open2 succeeds (no VPU device or no permission fails there).
// Otherwise the software decoder opens exactly as before. Only the software
// decoder gets thread_count 0 (one thread per core); rkmpp decodes on the VPU.
#pragma once

#include <string>

#include "video/FfmpegCopyAv.h"

namespace rni::ffv::RNI_FF_NS {

struct OpenedDecoder {
  AVCodecContext* ctx = nullptr;
  bool hw = false;
  std::string hwOff;  // why the software decoder opened ("" when hw)
};

// Opens the decoder for `st`: rkmpp when the rules above allow it, else `sw`.
// false + *error only when the software decoder fails too.
bool OpenVideoDecoder(const Av& av, const AVStream& st, const AVCodec* sw, OpenedDecoder* out,
                      std::string* error);

// A hardware frame (rkmpp: DRM_PRIME, an NV12 dmabuf) copied into `sw` as its
// software format. `sw` keeps its buffer while the size holds. < 0 = AVERROR.
int CopyOutHwFrame(const Av& av, const AVFrame& hw, AVFrame* sw);

}  // namespace rni::ffv::RNI_FF_NS
