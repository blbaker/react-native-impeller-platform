// Row 3 video, linux: Input, the demux side of one ffmpeg copy
// (video/FfmpegCopyInput.h). Compiled once per copy with FfmpegCopy.cpp.
#include "video/FfmpegCopyInput.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "video/FfmpegDecoder.h"

namespace rni::ffv::RNI_FF_NS {
namespace {

// A server that stops sending fails the read after this long instead of
// hanging the player (rw_timeout is copied to HLS segment requests too).
constexpr int64_t kRwTimeoutUs = 15 * 1000 * 1000;
// Read-ahead bound: this much video, or this many bytes, past the decoder.
constexpr double kReadAheadSec = 10;
constexpr int64_t kReadAheadBytes = 64 << 20;
constexpr size_t kReadAheadPackets = 1200;  // when the packets carry no dts

// The audio queue's own bound, past the video one: reached only when the sound
// thread stopped draining (a blocked device), and then its oldest packets go.
constexpr double kAudioQueueSec = kReadAheadSec + 2;

// The packets in `q` span at least `sec` of stream time.
template <class Q>
bool SpanAtLeast(const Q& q, AVRational tb, double sec) {
  if (q.empty()) return false;
  const AVPacket* a = q.front().pkt;
  const AVPacket* b = q.back().pkt;
  if (a->dts == AV_NOPTS_VALUE || b->dts == AV_NOPTS_VALUE) return q.size() >= kReadAheadPackets;
  return (double)(b->dts - a->dts) * av_q2d(tb) >= sec;
}

bool IsNetwork(const std::string& s) { return s.rfind("http://", 0) == 0 || s.rfind("https://", 0) == 0; }

// The request runs TLS: https, or an AES-128 HLS segment over https.
bool HasTlsLeg(const char* url) {
  if (std::strncmp(url, "crypto+", 7) == 0 || std::strncmp(url, "crypto:", 7) == 0) url += 7;
  return std::strncmp(url, "https://", 8) == 0;
}

}  // namespace

Input::~Input() {
  Abort();
  if (reader_.joinable()) reader_.join();
  {
    std::lock_guard<std::mutex> lock(mu_);
    DropQueues();
  }
  if (fmt_) av_.avformat_close_input(&fmt_);
}

bool Input::Fail(const std::string& what, int err, std::string* error) {
  if (error) *error = AvError(av_, what, err);
  return false;
}

int Input::Interrupted(void* self) { return static_cast<Input*>(self)->abort_.load() ? 1 : 0; }

// Every request of a network source. tls_verify=1 (and RNI_VIDEO_CA_FILE) go
// on each one, because ffmpeg 8 defaults verification OFF and the hls demuxer
// forwards only headers/user_agent/cookies/http_proxy/referer/rw_timeout/icy to
// its segment requests. A TLS request that leaves tls_verify unconsumed did not
// verify, so it is refused. Plain http gets the keys too (a redirect to https
// consumes them); there they are unused by design and are removed again.
int Input::OpenIo(AVFormatContext* s, AVIOContext** pb, const char* url, int flags,
                  AVDictionary** options) {
  auto* self = static_cast<Input*>(s->opaque);
  const Av& av = self->av_;
  AVDictionary* local = nullptr;
  AVDictionary** o = options ? options : &local;
  av.av_dict_set(o, "tls_verify", "1", 0);
  if (!self->caFile_.empty()) av.av_dict_set(o, "ca_file", self->caFile_.c_str(), 0);
  int r = self->defaultIo_(s, pb, url, flags, o);
  if (r >= 0 && HasTlsLeg(url) && av.av_dict_get(*o, "tls_verify", nullptr, 0) != nullptr) {
    std::fprintf(stderr, "rn-impeller: video refused %s: the TLS layer did not take tls_verify\n",
                 RedactUri(url).c_str());
    s->io_close2(s, *pb);
    *pb = nullptr;
    r = AVERROR(EPROTO);
  }
  av.av_dict_set(o, "tls_verify", nullptr, 0);
  av.av_dict_set(o, "ca_file", nullptr, 0);
  av.av_dict_free(&local);
  return r;
}

bool Input::Open(const std::string& source, std::string* error) {
  const std::string shown = RedactUri(source);
  network_ = IsNetwork(source);
  fmt_ = av_.avformat_alloc_context();
  if (!fmt_) return Fail("could not open " + shown, AVERROR(ENOMEM), error);
  fmt_->interrupt_callback.callback = &Input::Interrupted;
  fmt_->interrupt_callback.opaque = this;
  AVDictionary* opts = nullptr;
  if (network_) {
    if (const char* ca = std::getenv("RNI_VIDEO_CA_FILE"); ca && *ca) caFile_ = ca;
    fmt_->opaque = this;
    defaultIo_ = fmt_->io_open;
    fmt_->io_open = &Input::OpenIo;
    av_.av_dict_set(&opts, "protocol_whitelist", "http,https,tls,tcp,crypto", 0);
    av_.av_dict_set(&opts, "rw_timeout", std::to_string(kRwTimeoutUs).c_str(), 0);
    av_.av_dict_set(&opts, "reconnect", "1", 0);
  }
  int r = av_.avformat_open_input(&fmt_, source.c_str(), nullptr, &opts);  // frees fmt_ on failure
  std::string ignored;  // an option ffmpeg left in the dict was never applied
  for (const AVDictionaryEntry* e = nullptr; (e = av_.av_dict_get(opts, "", e, AV_DICT_IGNORE_SUFFIX));)
    ignored += std::string(ignored.empty() ? "" : ",") + e->key;
  av_.av_dict_free(&opts);
  if (r < 0) return Fail("could not open " + shown, r, error);
  if (!ignored.empty()) return Fail("could not open " + shown + ": ffmpeg did not apply " + ignored, 0, error);
  if ((r = av_.avformat_find_stream_info(fmt_, nullptr)) < 0) return Fail("no stream info", r, error);
  si_ = av_.av_find_best_stream(fmt_, AVMEDIA_TYPE_VIDEO, -1, -1, &codec_, 0);
  if (si_ < 0 || !codec_) return Fail("no decodable video stream in " + shown, si_, error);
  // The audio stream related to it: for HLS, the one in the same variant.
  ai_ = av_.av_find_best_stream(fmt_, AVMEDIA_TYPE_AUDIO, -1, si_, &acodec_, 0);
  if (ai_ < 0 || !acodec_) ai_ = -1, acodec_ = nullptr;
  // Only the chosen streams are read; for HLS this also stops the other variants' downloads.
  for (unsigned i = 0; i < fmt_->nb_streams; ++i)
    fmt_->streams[i]->discard = (int)i == si_ || (int)i == ai_ ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
  return true;
}

void Input::Start() {
  reader_ = std::thread([this] { Read(); });
}

bool Input::FullLocked() const {
  // Only the video queue (and the byte total) stops the reader. The audio
  // queue never does: a sound device that blocks, or dies slowly, must not
  // starve the picture. Its consumer runs on the same clock, so it stays near
  // the video queue's span; when it does not, Read() drops its oldest packets.
  return queuedBytes_ >= kReadAheadBytes || SpanAtLeast(queue_, fmt_->streams[si_]->time_base, kReadAheadSec);
}

void Input::DropQueues() {
  for (Queued& q : queue_) av_.av_packet_free(&q.pkt);
  for (Queued& q : aqueue_) av_.av_packet_free(&q.pkt);
  queue_.clear();
  aqueue_.clear();
  queuedBytes_ = 0;
}

void Input::Read() {
  while (true) {
    {
      std::unique_lock<std::mutex> lock(mu_);
      cv_.wait(lock, [this] { return abort_ || parkReq_ || (readErr_ == 0 && !FullLocked()); });
      if (abort_) return;
      if (parkReq_) {
        parked_ = true;
        cv_.notify_all();
        cv_.wait(lock, [this] { return abort_ || !parkReq_; });
        parked_ = false;
        continue;
      }
    }
    AVPacket* p = av_.av_packet_alloc();
    const int r = p ? av_.av_read_frame(fmt_, p) : AVERROR(ENOMEM);
    std::lock_guard<std::mutex> lock(mu_);
    if (r < 0 || (p->stream_index != si_ && (ai_ < 0 || p->stream_index != ai_))) {
      if (p) av_.av_packet_free(&p);
      if (r < 0 && r != AVERROR(EAGAIN)) readErr_ = r;
      cv_.notify_all();
      continue;
    }
    queuedBytes_ += p->size;
    (p->stream_index == si_ ? queue_ : aqueue_).push_back(Queued{p});
    while (p->stream_index == ai_ && aqueue_.size() > 1 &&
           SpanAtLeast(aqueue_, fmt_->streams[ai_]->time_base, kAudioQueueSec)) {
      queuedBytes_ -= aqueue_.front().pkt->size;
      av_.av_packet_free(&aqueue_.front().pkt);
      aqueue_.pop_front();
    }
    cv_.notify_all();
  }
}

int Input::Next(AVPacket** out) {
  std::unique_lock<std::mutex> lock(mu_);
  if (queue_.empty() && readErr_ == 0 && !abort_) {
    const auto t0 = std::chrono::steady_clock::now();
    cv_.wait(lock, [this] { return abort_ || !queue_.empty() || readErr_ != 0; });
    waited_ += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  }
  if (abort_) return AVERROR_EXIT;
  if (queue_.empty()) return readErr_;
  return Pop(false, out);
}

int Input::NextAudio(AVPacket** out, uint64_t* gen) {
  std::unique_lock<std::mutex> lock(mu_);
  cv_.wait(lock, [this] { return abort_ || !aqueue_.empty() || readErr_ != 0 || ai_ < 0; });
  *gen = gen_;
  if (abort_) return AVERROR_EXIT;
  if (aqueue_.empty()) return ai_ < 0 ? AVERROR_EOF : readErr_;
  return Pop(true, out);
}

int Input::Pop(bool audio, AVPacket** out) {
  std::deque<Queued>& q = audio ? aqueue_ : queue_;
  *out = q.front().pkt;
  q.pop_front();
  queuedBytes_ -= (*out)->size;
  cv_.notify_all();
  return 0;
}

bool Input::ParkReader(std::unique_lock<std::mutex>& lock) {
  parkReq_ = true;
  cv_.notify_all();
  cv_.wait(lock, [this] { return abort_ || parked_; });  // the reader finishes its read first
  if (abort_) parkReq_ = false;
  return !abort_;
}

void Input::DisableAudio() {
  std::lock_guard<std::mutex> park(parkMu_);
  std::unique_lock<std::mutex> lock(mu_);
  if (ai_ < 0) return;
  if (!ParkReader(lock)) return;
  fmt_->streams[ai_]->discard = AVDISCARD_ALL;
  ai_ = -1;
  for (Queued& q : aqueue_) {
    queuedBytes_ -= q.pkt->size;
    av_.av_packet_free(&q.pkt);
  }
  aqueue_.clear();
  parkReq_ = false;
  cv_.notify_all();
}

int Input::Seek(int64_t ts, int flags) {
  std::lock_guard<std::mutex> park(parkMu_);
  {
    std::unique_lock<std::mutex> lock(mu_);
    if (!ParkReader(lock)) return AVERROR_EXIT;
  }
  const int r = av_.av_seek_frame(fmt_, si_, ts, flags);
  std::lock_guard<std::mutex> lock(mu_);
  DropQueues();
  ++gen_;
  readErr_ = 0;
  waited_ = 0;
  parkReq_ = false;
  cv_.notify_all();
  return r;
}

void Input::Abort() {
  abort_ = true;
  { std::lock_guard<std::mutex> lock(mu_); }  // a waiter between its check and wait() sees the flag
  cv_.notify_all();
}

uint64_t Input::Gen() {
  std::lock_guard<std::mutex> lock(mu_);
  return gen_;
}

double Input::TakeWaited() {
  std::lock_guard<std::mutex> lock(mu_);
  const double w = waited_;
  waited_ = 0;
  return w;
}

}  // namespace rni::ffv::RNI_FF_NS
