// Row 3 video, linux: decoder choice and hardware frame copy-out for one
// ffmpeg copy (video/FfmpegCopyHw.h).
#include "video/FfmpegCopyHw.h"

#include <cstdlib>
#include <cstring>

namespace rni::ffv::RNI_FF_NS {
namespace {

const char* RkmppName(AVCodecID id) {  // the decoders n8.0.1 rkmppdec.c registers that the console uses
  switch (id) {
    case AV_CODEC_ID_H264: return "h264_rkmpp";
    case AV_CODEC_ID_HEVC: return "hevc_rkmpp";
    case AV_CODEC_ID_VP9: return "vp9_rkmpp";
    default: return nullptr;
  }
}

bool HwForcedOff() {
  const char* v = std::getenv("RNI_VIDEO_HW");
  return v != nullptr && std::strcmp(v, "0") == 0;
}

// The rkmpp decoder to try for `par`, or nullptr and *why.
const AVCodec* HwCandidate(const Av& av, const AVCodecParameters& par, const AVCodec& sw, std::string* why) {
  if (HwForcedOff()) return *why = "RNI_VIDEO_HW=0", nullptr;
  const char* name = RkmppName(par.codec_id);
  if (!name) return *why = std::string("no rkmpp decoder for ") + sw.name, nullptr;
  const AVCodec* hw = av.avcodec_find_decoder_by_name(name);
  if (!hw) return *why = std::string("no ") + name + " decoder in this ffmpeg", nullptr;
  const auto fmt = static_cast<AVPixelFormat>(par.format);
  if (fmt != AV_PIX_FMT_YUV420P && fmt != AV_PIX_FMT_YUVJ420P) {
    const char* f = av.av_get_pix_fmt_name(fmt);
    return *why = std::string(name) + " hands out NV12 only and this stream is " + (f ? f : "an unknown pixel format"),
           nullptr;
  }
  return hw;
}

// alloc + parameters + open; nullptr and *error (the context freed) on failure.
AVCodecContext* Open(const Av& av, const AVStream& st, const AVCodec* codec, bool cpuThreads, std::string* error) {
  AVCodecContext* c = av.avcodec_alloc_context3(codec);
  if (!c) return *error = "decoder alloc", nullptr;
  int r = av.avcodec_parameters_to_context(c, st.codecpar);
  if (r < 0) {
    *error = AvError(av, "codec params", r);
  } else {
    if (cpuThreads) c->thread_count = 0;  // auto
    if ((r = av.avcodec_open2(c, codec, nullptr)) < 0) *error = AvError(av, "open decoder", r);
  }
  if (r < 0) av.avcodec_free_context(&c);
  return c;
}

}  // namespace

bool OpenVideoDecoder(const Av& av, const AVStream& st, const AVCodec* sw, OpenedDecoder* out,
                      std::string* error) {
  std::string why;
  if (const AVCodec* hw = HwCandidate(av, *st.codecpar, *sw, &why)) {
    if ((out->ctx = Open(av, st, hw, false, &why)) != nullptr) {
      out->hw = true;
      out->hwOff.clear();
      return true;
    }
    why = std::string(hw->name) + " did not open (" + why + ")";
  }
  out->hw = false;
  out->hwOff = why;
  out->ctx = Open(av, st, sw, true, error);
  return out->ctx != nullptr;
}

int CopyOutHwFrame(const Av& av, const AVFrame& hw, AVFrame* sw) {
  const auto& fc = *reinterpret_cast<const AVHWFramesContext*>(hw.hw_frames_ctx->data);
  if (sw->format != fc.sw_format || sw->width != hw.width || sw->height != hw.height || !sw->buf[0]) {
    av.av_frame_unref(sw);
    sw->format = fc.sw_format;
    sw->width = hw.width;
    sw->height = hw.height;
    if (const int r = av.av_frame_get_buffer(sw, 0); r < 0) return r;
  }
  // A preallocated destination: hwcontext_drm.c:223-252 maps the dmabuf and
  // copies its planes (at MPP's padded pitch) into this frame's buffer.
  return av.av_hwframe_transfer_data(sw, &hw, 0);
}

}  // namespace rni::ffv::RNI_FF_NS
