// Row 3 video, linux: the demux side of ONE ffmpeg copy (see
// video/FfmpegCopyAv.h for how a copy is compiled). Input opens a source and
// runs a read-ahead thread that fills a bounded queue with the chosen video
// stream's packets, so a slow network read stalls this thread, not the decoder.
//
// The audio stream that belongs with it (same HLS variant) is queued too,
// for video/FfmpegCopyAudio.h, unless DisableAudio() turned it off.
//
// Sources: a local path, or an http:// / https:// URL (MP4 with byte-range
// seek, or an HLS .m3u8, live or VOD). For network sources:
// - every request the demuxer makes (HLS playlists, segments and keys
//   included) goes through OpenIo(), which forces TLS verification on: ffmpeg
//   8 defaults tls_verify to 0, and the hls demuxer does not pass it on to
//   segment requests. RNI_VIDEO_CA_FILE=<pem> replaces the system CA store.
// - Abort() (any thread) breaks a blocked read through the interrupt callback,
//   so releasing a player never waits on the network.
// - streams other than the chosen video stream are discarded, which keeps the
//   hls demuxer from downloading every variant.
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

#include "video/FfmpegCopyAv.h"

namespace rni::ffv::RNI_FF_NS {

class Input {
 public:
  explicit Input(const Av& av) : av_(av) {}
  ~Input();

  // Opens the source and picks its video stream (and the audio stream that
  // goes with it, if any); no thread runs yet.
  bool Open(const std::string& source, std::string* error);
  AVFormatContext* fmt() const { return fmt_; }
  int videoStream() const { return si_; }
  const AVCodec* videoCodec() const { return codec_; }
  int audioStream() const { return ai_; }  // -1 = none
  const AVCodec* audioCodec() const { return acodec_; }

  void Start();  // starts the read-ahead thread
  // Next queued packet of the video stream (caller frees it with
  // av_packet_free). Blocks while the queue is empty. Returns 0 = *out set,
  // AVERROR_EOF = end of input, other < 0 = read error or aborted.
  int Next(AVPacket** out);
  // The same for the audio stream; *gen = the seek generation the packet
  // was read in (Seek() bumps it), so the audio decoder knows when to flush.
  int NextAudio(AVPacket** out, uint64_t* gen);
  // Stops reading audio (no sound output): discards the stream, drops its queue.
  void DisableAudio();
  uint64_t Gen();  // the current seek generation
  // Parks the reader, seeks, drops the queue. The reader resumes after.
  int Seek(int64_t ts, int flags);
  void Abort();  // thread-safe: unblocks reads, Next() and Seek()
  bool Aborted() const { return abort_.load(); }
  // Seconds Next() spent waiting on an empty queue since the last call.
  double TakeWaited();

 private:
  static int Interrupted(void* self);
  static int OpenIo(AVFormatContext* s, AVIOContext** pb, const char* url, int flags,
                    AVDictionary** options);
  bool Fail(const std::string& what, int err, std::string* error);
  void Read();       // the read-ahead thread
  void DropQueues();  // mu_ held
  bool FullLocked() const;
  int Pop(bool audio, AVPacket** out);  // mu_ held, queue not empty
  bool ParkReader(std::unique_lock<std::mutex>& lock);  // false = aborted

  const Av& av_;
  AVFormatContext* fmt_ = nullptr;
  const AVCodec* codec_ = nullptr;
  const AVCodec* acodec_ = nullptr;
  int si_ = -1, ai_ = -1;
  bool network_ = false;
  std::string caFile_;
  int (*defaultIo_)(AVFormatContext*, AVIOContext**, const char*, int, AVDictionary**) = nullptr;

  std::atomic<bool> abort_{false};
  std::thread reader_;
  std::mutex parkMu_;  // one parker at a time (Seek, DisableAudio); taken before mu_
  std::mutex mu_;
  std::condition_variable cv_;
  // A copy-local wrapper, not AVPacket* itself: std::deque<AVPacket*> would be
  // one COMDAT shared by both copies (video/FfmpegDecoder.h, ci-video-ffmpeg8 PKG).
  struct Queued {
    AVPacket* pkt;
  };
  std::deque<Queued> queue_, aqueue_;  // video, audio
  int64_t queuedBytes_ = 0;             // both queues
  uint64_t gen_ = 0;                    // seek generation
  int readErr_ = 0;  // < 0 once the reader hit the end (AVERROR_EOF) or an error
  bool parkReq_ = false, parked_ = false;
  double waited_ = 0;
};

}  // namespace rni::ffv::RNI_FF_NS
