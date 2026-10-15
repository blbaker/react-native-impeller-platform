#include "ImageStore.h"
#include "base/Trace.h"

#include <cstdio>
#include <mutex>
#include <thread>
#include <unordered_map>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_GIF
#define STBI_ONLY_BMP
#define STBI_NO_STDIO
#include "stb_image.h"

#include <condition_variable>

namespace rni::image {
namespace {

std::mutex gMutex;
// A failed URI maps to null so the painter does not retry the decode each frame.
std::unordered_map<std::string, std::shared_ptr<const Decoded>> gCache;
// SC-31: remote loads in flight, keyed by URI; every waiter gets the one result.
std::unordered_map<std::string, std::vector<LoadDone>> gPending;
Fetcher gFetch;
std::function<void()> gBegin, gEnd;
// FP-06 teardown fence: completions that finish after StopCallbacks() drop their waiters;
// StopCallbacks() returns only once no completion callback is still running.
bool gCallbacksStopped = false;
int gCallbacksRunning = 0;
std::condition_variable gCallbacksIdle;

int HexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

std::string PercentDecode(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '%' && i + 2 < s.size() && HexVal(s[i + 1]) >= 0 && HexVal(s[i + 2]) >= 0) {
      out.push_back((char)(HexVal(s[i + 1]) * 16 + HexVal(s[i + 2])));
      i += 2;
    } else {
      out.push_back(s[i]);
    }
  }
  return out;
}

int B64Val(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+' || c == '-') return 62;
  if (c == '/' || c == '_') return 63;
  return -1;
}

void Base64Decode(const std::string& s, std::vector<uint8_t>& out) {
  uint32_t acc = 0;
  int bits = 0;
  for (char c : s) {
    const int v = B64Val(c);
    if (v < 0) continue;  // '=', whitespace, line breaks
    acc = (acc << 6) | (uint32_t)v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back((uint8_t)((acc >> bits) & 0xFF));
    }
  }
}

bool ReadFile(const std::string& path, std::vector<uint8_t>& out) {
  FILE* f = std::fopen(path.c_str(), "rb");
  if (f == nullptr) return false;
  uint8_t buf[65536];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) out.insert(out.end(), buf, buf + n);
  std::fclose(f);
  return !out.empty();
}

std::shared_ptr<const Decoded> Decode(const std::vector<uint8_t>& bytes) {
  TRACE_EVENT1("image", "ImageDecode", "bytes", bytes.size());
  int w = 0, h = 0, comp = 0;
  stbi_uc* px = stbi_load_from_memory(bytes.data(), (int)bytes.size(), &w, &h, &comp, 4);
  if (px == nullptr || w <= 0 || h <= 0) {
    if (px) stbi_image_free(px);
    return nullptr;
  }
  auto d = std::make_shared<Decoded>();
  d->width = w;
  d->height = h;
  d->rgba.assign(px, px + (size_t)w * (size_t)h * 4);
  stbi_image_free(px);
  for (size_t i = 0; i < d->rgba.size(); i += 4) {
    const unsigned a = d->rgba[i + 3];
    if (a == 255) continue;
    for (int c = 0; c < 3; ++c) d->rgba[i + c] = (uint8_t)((d->rgba[i + c] * a + 127) / 255);
  }
  return d;
}

}  // namespace

bool ReadSourceBytes(const std::string& uri, std::vector<uint8_t>& out) {
  if (uri.rfind("data:", 0) == 0) {
    const size_t comma = uri.find(',');
    if (comma == std::string::npos) return false;
    const std::string meta = uri.substr(5, comma - 5);
    const std::string payload = uri.substr(comma + 1);
    if (meta.size() >= 7 && meta.compare(meta.size() - 7, 7, ";base64") == 0) {
      Base64Decode(payload, out);
    } else {
      const std::string raw = PercentDecode(payload);
      out.assign(raw.begin(), raw.end());
    }
    return !out.empty();
  }
  if (uri.rfind("file://", 0) == 0) {
    // file:///abs/path or file://localhost/abs/path
    std::string rest = uri.substr(7);
    if (rest.rfind("localhost/", 0) == 0) rest = rest.substr(9);
    const size_t q = rest.find_first_of("?#");
    if (q != std::string::npos) rest.resize(q);
    return ReadFile(PercentDecode(rest), out);
  }
  if (!uri.empty() && uri[0] == '/') return ReadFile(uri, out);
#ifdef _WIN32
  if (uri.size() > 2 && uri[1] == ':') return ReadFile(uri, out);
#endif
  return false;
}

bool IsRemote(const std::string& uri) {
  return uri.rfind("http://", 0) == 0 || uri.rfind("https://", 0) == 0;
}

std::shared_ptr<const Decoded> Load(const std::string& uri) {
  {
    std::lock_guard<std::mutex> lock(gMutex);
    auto it = gCache.find(uri);
    if (it != gCache.end()) return it->second;
  }
  if (IsRemote(uri)) return nullptr;
  std::vector<uint8_t> bytes;
  std::shared_ptr<const Decoded> d = ReadSourceBytes(uri, bytes) ? Decode(bytes) : nullptr;
  std::lock_guard<std::mutex> lock(gMutex);
  return gCache.emplace(uri, d).first->second;
}

std::shared_ptr<const Decoded> Peek(const std::string& uri) {
  std::lock_guard<std::mutex> lock(gMutex);
  auto it = gCache.find(uri);
  return it == gCache.end() ? nullptr : it->second;
}

void SetFetcher(Fetcher fetch, std::function<void()> begin, std::function<void()> end) {
  std::lock_guard<std::mutex> lock(gMutex);
  gFetch = std::move(fetch);
  gBegin = std::move(begin);
  gEnd = std::move(end);
}

namespace {

LoadResult FetchAndDecode(const Fetcher& fetch, const std::string& uri, const Headers& headers) {
  LoadResult r;
  if (!fetch) {
    r.error = "no network transport for " + uri;
    return r;
  }
  FetchResult f;
  {
    TRACE_EVENT0("image", "ImageFetch");
    f = fetch(uri, headers);
  }
  r.status = f.status;
  r.headers = std::move(f.headers);
  if (!f.ok) {
    r.error = f.error.empty() ? "request failed" : f.error;
    return r;
  }
  const std::vector<uint8_t> bytes(f.body.begin(), f.body.end());
  r.image = bytes.empty() ? nullptr : Decode(bytes);
  if (!r.image) r.error = "could not decode the image at " + uri;
  return r;
}

}  // namespace

void LoadAsync(const std::string& uri, const Headers& headers, LoadDone done) {
  if (!IsRemote(uri)) {
    LoadResult r;
    r.image = Load(uri);
    if (!r.image) r.error = "could not load " + uri;
    done(r);
    return;
  }
  Fetcher fetch;
  std::function<void()> begin, end;
  std::shared_ptr<const Decoded> cached;
  bool start = false;
  {
    std::lock_guard<std::mutex> lock(gMutex);
    auto hit = gCache.find(uri);
    if (hit != gCache.end()) cached = hit->second;
    if (!cached) {
      auto& waiters = gPending[uri];
      waiters.push_back(std::move(done));
      start = waiters.size() == 1;  // else a fetch for this URI is already running
      fetch = gFetch;
      begin = gBegin;
      end = gEnd;
    }
  }
  if (cached) {  // `done` runs without the store lock
    LoadResult r;
    r.image = std::move(cached);
    done(r);
    return;
  }
  if (!start) return;
  if (begin) begin();
  std::thread([uri, headers, fetch = std::move(fetch), end = std::move(end)]() {
    rni::trace::SetThreadName("image-io");
    LoadResult r = FetchAndDecode(fetch, uri, headers);
    std::vector<LoadDone> waiters;
    {
      std::lock_guard<std::mutex> lock(gMutex);
      if (r.image) gCache[uri] = r.image;
      waiters = std::move(gPending[uri]);
      gPending.erase(uri);
      if (gCallbacksStopped) waiters.clear();
      else ++gCallbacksRunning;
    }
    if (!waiters.empty()) {
      for (auto& w : waiters) w(r);
      std::lock_guard<std::mutex> lock(gMutex);
      if (--gCallbacksRunning == 0) gCallbacksIdle.notify_all();
    }
    if (end) end();
  }).detach();
}

void StopCallbacks() {
  std::unique_lock<std::mutex> lock(gMutex);
  gCallbacksStopped = true;
  gCallbacksIdle.wait(lock, [] { return gCallbacksRunning == 0; });
}

void StartCallbacks() {
  std::lock_guard<std::mutex> lock(gMutex);
  gCallbacksStopped = false;
}

}  // namespace rni::image
