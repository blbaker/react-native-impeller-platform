#pragma once

// A19 (SC-30): decoded <Image> sources, shared by the Fabric ImageManager
// (decodes on request, off the paint thread) and the painter (reads pixels).
// Local sources: data: URIs (base64 or percent-encoded), file:// URLs and
// absolute paths. SC-31: http(s) sources load on a worker through the host's
// fetcher (NetworkingModule's transport) into the same in-memory cache.

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace rni::image {

struct Decoded {
  int width{0};
  int height{0};
  // Tightly packed RGBA8, PREMULTIPLIED (Impeller samples premultiplied).
  std::vector<uint8_t> rgba;
};

using Headers = std::vector<std::pair<std::string, std::string>>;

// Decodes (first frame of PNG/JPEG/GIF/BMP) or returns the cached result for
// `uri`. Null when the URI is unreadable or undecodable. A remote URI is never
// fetched here: it returns the cached image or null. Thread-safe.
std::shared_ptr<const Decoded> Load(const std::string& uri);

// The cached result only; never decodes. Null if Load never succeeded.
std::shared_ptr<const Decoded> Peek(const std::string& uri);

bool IsRemote(const std::string& uri);

// One HTTP GET as the host performs it. `ok` is false on a transport error or
// a non-2xx status (then `error` says why and `status` is the HTTP code or 0).
struct FetchResult {
  bool ok{false};
  std::string error;
  int status{0};
  Headers headers;
  std::string body;
};
using Fetcher = std::function<FetchResult(const std::string& uri, const Headers& headers)>;

// Installed by the host. `begin`/`end` bracket every remote load (fetch, decode
// and the completion callbacks) so a headless run can wait for images.
void SetFetcher(Fetcher fetch, std::function<void()> begin, std::function<void()> end);

struct LoadResult {
  std::shared_ptr<const Decoded> image;  // null on failure
  std::string error;
  int status{0};
  Headers headers;
};
using LoadDone = std::function<void(const LoadResult&)>;

// Local URIs and cached remote ones complete inline. Other remote URIs are
// fetched on a worker thread, `done` runs there; concurrent loads of one URI
// share one fetch. Remote failures are not cached, so a later load retries.
void LoadAsync(const std::string& uri, const Headers& headers, LoadDone done);

// Exposed for tests: the bytes a local URI names, or false.
bool ReadSourceBytes(const std::string& uri, std::vector<uint8_t>& out);

}  // namespace rni::image
