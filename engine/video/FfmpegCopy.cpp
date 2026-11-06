// Row 3 video, linux: ONE ffmpeg copy (see video/FfmpegDecoder.h). This file
// and its demux side, video/FfmpegCopyInput.cpp, are compiled once per ffmpeg
// release that has headers, as one object library with RNI_FF_RELEASE=<8|6>
// and that release's include dir (engine/CMakeLists.txt, RNI_FFMPEG_COPIES).
// Everything here lives in rni::ffv::copy<N>; the only symbol the rest of the
// engine sees is rni::ffv::Ffmpeg<N>Copy().
//
// Loading (first use, cached): dlopen this release's soname set from
// host/OptionalLibs (the table --doctor reports), RTLD_LOCAL, so the binary has
// no link-time ffmpeg dependency and starts on a host without it. Then the
// RUNTIME MAJOR CHECK: avutil/avcodec/avformat/swscale _version() >> 16 must
// equal the majors of the headers this copy was compiled with. A mismatch is
// refused (handles closed, never used): the decode code reads AVFrame and
// AVCodecContext fields directly, so a different major is memory corruption.
#include <dlfcn.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

#include "host/OptionalLibs.h"
#include "video/FfmpegCopyAudio.h"
#include "video/FfmpegCopyAv.h"
#include "video/FfmpegCopyHw.h"
#include "video/FfmpegCopyInput.h"
#include "video/FfmpegDecoder.h"

// The include dir must BE the release the copy claims to be.
static_assert(RNI_FF_RELEASE != 8 || LIBAVCODEC_VERSION_MAJOR == 62, "ffmpeg 8 copy: headers are not avcodec 62");
static_assert(RNI_FF_RELEASE != 6 || LIBAVCODEC_VERSION_MAJOR == 60, "ffmpeg 6 copy: headers are not avcodec 60");

namespace rni::ffv::RNI_FF_NS {
namespace {

const std::string kName = "ffmpeg " + std::to_string(RNI_FF_RELEASE);

int LibIndex(const char* key) {  // RNI_AV_FUNCS library key -> FfmpegSet::sonames index
  return std::strcmp(key, "util") == 0 ? 0 : std::strcmp(key, "codec") == 0 ? 1 : std::strcmp(key, "fmt") == 0 ? 2 : 3;
}

const Av& LoadAv() {
  static const Av av = [] {
    Av a;
    const optlib::FfmpegSet* set = optlib::FfmpegSetForRelease(RNI_FF_RELEASE);
    if (set == nullptr) {
      a.error = kName + ": no soname set in host/OptionalLibs";
      return a;
    }
    void* h[4] = {nullptr, nullptr, nullptr, nullptr};  // util, codec, fmt, sws
    auto fail = [&h](std::string why) {  // close what loaded, return an unusable Av
      for (void*& p : h)
        if (p) dlclose(p), p = nullptr;
      Av z;
      z.error = std::move(why);
      return z;
    };
    std::string missing;  // EVERY soname that does not load, not just the first
    for (int i = 0; i < 4; ++i) {
      const char* so = set->sonames[i];
      h[i] = dlopen(so, RTLD_NOW | RTLD_LOCAL);
      if (h[i]) continue;
      const char* e = dlerror();
      const std::string why = e ? e : "dlopen failed";
      missing += (missing.empty() ? "" : ",") + std::string(so);
      // Not found is the soname itself; anything else (a NEEDED lib missing,
      // wrong arch) is worth printing.
      if (why.rfind(std::string(so) + ": cannot open shared object file", 0) != 0) missing += " (" + why + ")";
    }
    if (!missing.empty()) return fail(kName + " missing " + missing);
#define RNI_AV_LOAD(lib, fn)                                                            \
  a.fn = reinterpret_cast<decltype(&::fn)>(dlsym(h[LibIndex(#lib)], #fn));              \
  if (!a.fn) return fail(kName + ": symbol " #fn " missing in " + set->sonames[LibIndex(#lib)]);
    RNI_AV_FUNCS(RNI_AV_LOAD)
#undef RNI_AV_LOAD
    // ⛔ RUNTIME MAJOR CHECK: the loaded libs must be the ABI this copy was
    // compiled against, whatever their file names say.
    const unsigned got[4] = {a.avutil_version() >> 16, a.avcodec_version() >> 16,
                             a.avformat_version() >> 16, a.swscale_version() >> 16};
    const unsigned want[4] = {LIBAVUTIL_VERSION_MAJOR, LIBAVCODEC_VERSION_MAJOR,
                              LIBAVFORMAT_VERSION_MAJOR, LIBSWSCALE_VERSION_MAJOR};
    std::string refused;
    for (int i = 0; i < 4; ++i)
      if (got[i] != want[i])
        refused += (refused.empty() ? "" : ", ") + std::string(set->sonames[i]) + " reports major " +
                   std::to_string(got[i]) + " (compiled against " + std::to_string(want[i]) + ")";
    if (!refused.empty()) return fail(kName + " refused: " + refused + "; a mismatched ffmpeg is never used");
    // ffmpeg's own INFO lines name every URL it opens (HLS: each segment), and a
    // signed URL's query is a credential: errors only, unless RNI_VIDEO_LOG=1.
    a.av_log_set_level(VideoLog() ? AV_LOG_INFO : AV_LOG_ERROR);
    a.swrError = LoadSwr(&a);  // sound only: video plays without it
    a.ok = true;
    return a;
  }();
  return av;
}

class Dec final : public Decoder {
 public:
  explicit Dec(const Av& av) : av_(av), in_(av), audio_(av, in_) {}
  ~Dec() override {
    in_.Abort();  // the reader thread stops before the decoder goes away
    if (sws_) av_.sws_freeContext(sws_);
    for (AVFrame*& f : f_)
      if (f) av_.av_frame_free(&f);
    if (sw_) av_.av_frame_free(&sw_);
    av_.av_packet_free(&pending_);
    if (dec_) av_.avcodec_free_context(&dec_);
  }

  bool Open(const std::string& source, StreamInfo* info, std::string* error) override {
    if (!in_.Open(source, error)) return false;
    si_ = in_.videoStream();
    AVStream* st = in_.fmt()->streams[si_];
    OpenedDecoder od;  // rkmpp or the software decoder (video/FfmpegCopyHw.h)
    if (!OpenVideoDecoder(av_, *st, in_.videoCodec(), &od, error)) return false;
    dec_ = od.ctx;
    info->hw = od.hw;
    info->hwOff = od.hwOff;
    tb_ = av_q2d(st->time_base);
    startTs_ = st->start_time != AV_NOPTS_VALUE ? st->start_time : 0;
    const AVFormatContext* fmt = in_.fmt();
    info->duration = fmt->duration > 0 ? (double)fmt->duration / AV_TIME_BASE
                     : st->duration > 0 ? st->duration * tb_
                                        : 0;
    const AVRational fr = st->avg_frame_rate.num > 0 ? st->avg_frame_rate : st->r_frame_rate;
    frameDur_ = info->frameDur = fr.num > 0 ? (double)fr.den / fr.num : 1.0 / 30;
    info->width = dec_->width;
    info->height = dec_->height;
    info->codec = dec_->codec->name;  // "h264_rkmpp" on the VPU, "h264" in software
    f_[kNext] = av_.av_frame_alloc();
    f_[kTmp] = av_.av_frame_alloc();
    sw_ = av_.av_frame_alloc();
    if (!f_[kNext] || !f_[kTmp] || !sw_) return Err("frame alloc", 0, error);
    audioWhyNot_ = audio_.Open(startTs_ * tb_);
    if (!audioWhyNot_.empty()) in_.DisableAudio();  // nothing will read its packets
    in_.Start();
    return true;
  }

  int DecodeNext(Slot slot, double* pts, std::string* error) override {
    AVFrame* out = f_[slot];
    while (true) {
      int r = av_.avcodec_receive_frame(dec_, out);
      if (r == 0) {
        int64_t t = out->best_effort_timestamp;
        if (t == AV_NOPTS_VALUE) t = out->pts;
        *pts = t == AV_NOPTS_VALUE ? lastPts_ + frameDur_ : (t - startTs_) * tb_;
        lastPts_ = *pts;
        return 0;
      }
      if (r == AVERROR_EOF) return kEof;
      if (r != AVERROR(EAGAIN)) return Err("decode", r, error), -1;
      if (inputEof_) return kEof;
      if (!pending_) {
        r = in_.Next(&pending_);
        if (r == AVERROR_EOF) {
          if ((r = av_.avcodec_send_packet(dec_, nullptr)) < 0) Refused("the end of stream", r);  // drain
          inputEof_ = true;
          continue;
        }
        if (r < 0) return Err("decode", r, error), -1;
      }
      // EAGAIN = the decoder is full and kept nothing (n8.0.1 decode.c:717;
      // rkmpp stops taking packets with 4 queued, rkmppdec.c:499). Its output
      // is read first, then the SAME packet goes again.
      r = av_.avcodec_send_packet(dec_, pending_);
      if (r == AVERROR(EAGAIN)) {
        if (in_.Aborted()) return Err("decode", AVERROR_EXIT, error), -1;
        continue;
      }
      av_.av_packet_free(&pending_);
      if (r < 0) Refused("a packet", r);  // corrupt data: skipped as before, but no longer silently
    }
  }

  void Swap() override {
    av_.av_frame_unref(f_[kNext]);
    av_.av_frame_move_ref(f_[kNext], f_[kTmp]);
  }

  bool SeekBackward(double target, std::string* error) override {
    const int64_t ts = startTs_ + (int64_t)std::llround(target / tb_);
    const int r = in_.Seek(ts, AVSEEK_FLAG_BACKWARD);
    if (r < 0) return Err("seek", r, error);
    av_.av_packet_free(&pending_);  // read before the seek
    av_.avcodec_flush_buffers(dec_);
    inputEof_ = false;
    return true;
  }

  void Abort() override { in_.Abort(); }
  double TakeWaited() override { return in_.TakeWaited(); }

  std::string AudioUnavailable() override { return audioWhyNot_; }
  std::string AudioDescription() override { return audio_.Describe(); }
  int DecodeAudio(AudioChunk* out, std::string* error) override { return audio_.Decode(out, error); }
  void DisableAudio() override { in_.DisableAudio(); }

  bool ToRgba(Slot slot, std::vector<uint8_t>* rgba, int* width, int* height,
              std::string* error) override {
    const AVFrame* f = f_[slot];
    const AVFrame* px = f;  // the frame whose planes swscale reads
    if (f->hw_frames_ctx) {  // rkmpp: an NV12 dmabuf swscale cannot read, copied out first
      const int r = CopyOutHwFrame(av_, *f, sw_);
      if (r < 0) return Err("copy the frame out of the VPU buffer", r, error);
      px = sw_;
    }
    const int w = f->width, h = f->height;
    sws_ = av_.sws_getCachedContext(sws_, w, h, (AVPixelFormat)px->format, w, h, AV_PIX_FMT_RGBA,
                                    SWS_BILINEAR, nullptr, nullptr, nullptr);
    if (!sws_) return Err("no pixel converter for this format", 0, error);
    const int* src = av_.sws_getCoefficients(f->colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709
                                                                              : SWS_CS_DEFAULT);
    av_.sws_setColorspaceDetails(sws_, src, f->color_range == AVCOL_RANGE_JPEG ? 1 : 0, src, 1, 0,
                                 1 << 16, 1 << 16);
    rgba->resize((size_t)w * h * 4);
    uint8_t* dst[4] = {rgba->data(), nullptr, nullptr, nullptr};
    int dstStride[4] = {w * 4, 0, 0, 0};
    av_.sws_scale(sws_, px->data, px->linesize, 0, h, dst, dstStride);  // opaque: alpha 255
    *width = w;
    *height = h;
    return true;
  }

 private:
  bool Err(const std::string& what, int err, std::string* error) {
    char buf[128] = {0};
    if (err < 0) av_.av_strerror(err, buf, sizeof buf);
    if (error) *error = what + (buf[0] ? std::string(": ") + buf : std::string());
    return false;
  }

  void Refused(const char* what, int err) {
    std::fprintf(stderr, "%s\n",
                 AvError(av_, std::string("rn-impeller: video decoder ") + dec_->codec->name + " refused " + what, err)
                     .c_str());
  }

  const Av& av_;
  Input in_;  // declared first among the ffmpeg state: destroyed last (joins its reader)
  AudioDec audio_;
  std::string audioWhyNot_ = "not opened";
  AVCodecContext* dec_ = nullptr;
  AVFrame* f_[2] = {nullptr, nullptr};  // kNext, kTmp
  AVFrame* sw_ = nullptr;               // a hardware frame's planes, copied out for swscale
  AVPacket* pending_ = nullptr;         // read, not yet taken by the decoder (EAGAIN)
  SwsContext* sws_ = nullptr;
  int si_ = -1;
  double tb_ = 0, frameDur_ = 1.0 / 30, lastPts_ = 0;
  int64_t startTs_ = 0;
  bool inputEof_ = false;
};

bool Load(std::string* error) {
  const Av& a = LoadAv();
  if (!a.ok && error) *error = a.error;
  return a.ok;
}

std::unique_ptr<Decoder> Create() { return std::make_unique<Dec>(LoadAv()); }

}  // namespace
}  // namespace rni::ffv::RNI_FF_NS

namespace rni::ffv {
const Copy& RNI_FF_ENTRY() {
  static const Copy c{RNI_FF_RELEASE,
                      {LIBAVUTIL_VERSION_MAJOR, LIBAVCODEC_VERSION_MAJOR, LIBAVFORMAT_VERSION_MAJOR,
                       LIBSWSCALE_VERSION_MAJOR},
                      &RNI_FF_NS::Load,
                      &RNI_FF_NS::Create};
  return c;
}
}  // namespace rni::ffv
