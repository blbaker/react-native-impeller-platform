// Row 3 video, linux: AudioDec and the libswresample loader of one ffmpeg copy
// (video/FfmpegCopyAudio.h). Compiled once per copy with FfmpegCopy.cpp.
#include "video/FfmpegCopyAudio.h"

#include <dlfcn.h>

#include "host/OptionalLibs.h"

namespace rni::ffv::RNI_FF_NS {

std::string LoadSwr(Av* av) {
#if RNI_FF_HAS_SWR
  const std::string name = "ffmpeg " + std::to_string(RNI_FF_RELEASE);
  const char* so = optlib::SwresampleForRelease(RNI_FF_RELEASE);
  if (so == nullptr) return name + ": no libswresample soname in host/OptionalLibs";
  void* h = dlopen(so, RTLD_NOW | RTLD_LOCAL);
  if (h == nullptr) {
    const char* e = dlerror();
    return name + " missing " + so + (e ? std::string(" (") + e + ")" : std::string());
  }
#define RNI_SWR_LOAD(fn)                                                  \
  av->fn = reinterpret_cast<decltype(&::fn)>(dlsym(h, #fn));              \
  if (!av->fn) return name + ": symbol " #fn " missing in " + so;
  RNI_SWR_FUNCS(RNI_SWR_LOAD)
#undef RNI_SWR_LOAD
  const unsigned got = av->swresample_version() >> 16;
  if (got != LIBSWRESAMPLE_VERSION_MAJOR)
    return name + " refused " + so + ": reports major " + std::to_string(got) + " (compiled against " +
           std::to_string(LIBSWRESAMPLE_VERSION_MAJOR) + ")";
  return "";
#else
  (void)av;
  return "ffmpeg " + std::to_string(RNI_FF_RELEASE) + " copy built without libswresample headers";
#endif
}

AudioDec::~AudioDec() {
#if RNI_FF_HAS_SWR
  if (swr_) av_.swr_free(&swr_);
#endif
  if (f_) av_.av_frame_free(&f_);
  if (ctx_) av_.avcodec_free_context(&ctx_);
}

std::string AudioDec::Open(double originSec) {
  const int ai = in_.audioStream();
  if (ai < 0) return "no audio stream";
  if (!av_.swrError.empty()) return av_.swrError;
  const AVStream* st = in_.fmt()->streams[ai];
  ctx_ = av_.avcodec_alloc_context3(in_.audioCodec());
  if (!ctx_) return "audio decoder alloc";
  int r = av_.avcodec_parameters_to_context(ctx_, st->codecpar);
  if (r >= 0) r = av_.avcodec_open2(ctx_, in_.audioCodec(), nullptr);
  if (r < 0) return AvError(av_, "open audio decoder", r);
  f_ = av_.av_frame_alloc();
  if (!f_) return "audio frame alloc";
  tb_ = av_q2d(st->time_base);
  origin_ = originSec;
  gen_ = in_.Gen();
  return "";
}

std::string AudioDec::Describe() const {
  if (!ctx_) return "none";
  return std::string(ctx_->codec ? ctx_->codec->name : "?") + " " + std::to_string(ctx_->sample_rate) + " Hz " +
         std::to_string(ctx_->ch_layout.nb_channels) + " ch";
}

void AudioDec::Flush() {
  av_.avcodec_flush_buffers(ctx_);
#if RNI_FF_HAS_SWR
  if (swr_) av_.swr_free(&swr_);  // rebuilt on the next frame, with nothing buffered
#endif
  draining_ = eof_ = false;
}

int AudioDec::Decode(AudioChunk* out, std::string* error) {
  while (true) {
    const uint64_t g = in_.Gen();
    if (g != gen_) {  // frames still in the decoder belong before the seek
      Flush();
      gen_ = g;
    }
    if (!eof_) {
      const int r = av_.avcodec_receive_frame(ctx_, f_);
      if (r == 0) {
        const bool got = Convert(out, error);
        av_.av_frame_unref(f_);
        if (got) return 0;
        if (!error->empty()) return -1;
        continue;
      }
      if (r == AVERROR_EOF) {
        eof_ = true;
        return kEof;
      }
      if (r != AVERROR(EAGAIN)) return (*error = AvError(av_, "audio decode", r)), -1;
    }
    AVPacket* pkt = nullptr;
    uint64_t pg = 0;
    const int r = in_.NextAudio(&pkt, &pg);
    if (pg != gen_) {
      Flush();
      gen_ = pg;
    }
    if (r == AVERROR_EOF) {
      if (eof_) return kEof;
      if (!draining_) av_.avcodec_send_packet(ctx_, nullptr);
      draining_ = true;
      continue;
    }
    if (r < 0) return (*error = AvError(av_, "audio", r)), -1;
    av_.avcodec_send_packet(ctx_, pkt);
    av_.av_packet_free(&pkt);
  }
}

// f_ -> *out in the sink format. false with *error empty = nothing to emit.
bool AudioDec::Convert(AudioChunk* out, std::string* error) {
  error->clear();
  if (f_->nb_samples <= 0) return false;
  int64_t t = f_->best_effort_timestamp;
  if (t == AV_NOPTS_VALUE) t = f_->pts;
  const double pts = t == AV_NOPTS_VALUE ? nextPts_ : t * tb_ - origin_;
  nextPts_ = pts + (double)f_->nb_samples / f_->sample_rate;
#if RNI_FF_HAS_SWR
  if (swr_ && (swrFormat_ != f_->format || swrRate_ != f_->sample_rate || swrChannels_ != f_->ch_layout.nb_channels))
    av_.swr_free(&swr_);  // the stream changed format (an HLS discontinuity)
  if (!swr_) {
    AVChannelLayout in = f_->ch_layout, def{};
    if (in.order == AV_CHANNEL_ORDER_UNSPEC) {
      av_.av_channel_layout_default(&def, in.nb_channels);
      in = def;
    }
    AVChannelLayout stereo{};
    av_.av_channel_layout_default(&stereo, kAudioChannels);
    int r = av_.swr_alloc_set_opts2(&swr_, &stereo, AV_SAMPLE_FMT_S16, kAudioRate, &in, (AVSampleFormat)f_->format,
                                    f_->sample_rate, 0, nullptr);
    if (r >= 0) r = av_.swr_init(swr_);
    if (r < 0) {
      if (swr_) av_.swr_free(&swr_);
      *error = AvError(av_, "audio resampler", r);
      return false;
    }
    swrFormat_ = f_->format;
    swrRate_ = f_->sample_rate;
    swrChannels_ = f_->ch_layout.nb_channels;
  }
  const int cap = av_.swr_get_out_samples(swr_, f_->nb_samples);
  out->pcm.resize((size_t)cap * kAudioChannels);
  uint8_t* dst[1] = {reinterpret_cast<uint8_t*>(out->pcm.data())};
  const int n = av_.swr_convert(swr_, dst, cap, const_cast<const uint8_t**>(f_->extended_data), f_->nb_samples);
  if (n < 0) {
    *error = AvError(av_, "audio resample", n);
    return false;
  }
  out->pcm.resize((size_t)n * kAudioChannels);
  out->frames = n;
  out->pts = pts;
  out->gen = gen_;
  return n > 0;
#else
  (void)out;
  *error = av_.swrError;
  return false;
#endif
}

}  // namespace rni::ffv::RNI_FF_NS
