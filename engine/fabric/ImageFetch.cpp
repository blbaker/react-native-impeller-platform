// FP-16: remote image fetches, deduplicated per URI (split from ImageStore.cpp).
#include <deque>
#include <future>
#include <mutex>
#include <unordered_map>

#include "ImageInternal.h"
#include "base/Trace.h"

namespace rni::image {
namespace {

std::mutex gMutex;  // taken after ImageStore's lock, never before it
std::unordered_map<std::string, std::shared_future<FetchResult>> gFetches;
std::unordered_map<std::string, std::string> gBytes;
std::deque<std::string> gBytesOrder;
size_t gBytesTotal = 0;
constexpr size_t kBytesCap = 32u << 20;
Fetcher gFetch;
std::function<void()> gBegin, gEnd;

void StoreBytes(const std::string& uri, const std::string& body) {
  if (body.size() > kBytesCap || gBytes.count(uri)) return;
  while (gBytesTotal + body.size() > kBytesCap && !gBytesOrder.empty()) {
    gBytesTotal -= gBytes[gBytesOrder.front()].size();
    gBytes.erase(gBytesOrder.front());
    gBytesOrder.pop_front();
  }
  gBytes[uri] = body;
  gBytesOrder.push_back(uri);
  gBytesTotal += body.size();
}
}  // namespace

FetchResult FetchShared(const std::string& uri, const Headers& headers) {
  std::shared_ptr<std::promise<FetchResult>> mine;
  std::shared_future<FetchResult> theirs;
  Fetcher fetch;
  {
    std::lock_guard<std::mutex> lock(gMutex);
    auto it = gFetches.find(uri);
    if (it != gFetches.end()) {
      theirs = it->second;
    } else {
      mine = std::make_shared<std::promise<FetchResult>>();
      gFetches[uri] = mine->get_future().share();
      fetch = gFetch;
    }
  }
  if (!mine) return theirs.get();
  FetchResult f;
  if (!fetch) {
    f.error = "no network transport for " + uri;
  } else {
    TRACE_EVENT0("image", "ImageFetch");
    f = fetch(uri, headers);
  }
  {
    std::lock_guard<std::mutex> lock(gMutex);
    gFetches.erase(uri);
    if (f.ok) StoreBytes(uri, f.body);
  }
  mine->set_value(f);
  return f;
}

bool CachedBody(const std::string& uri, std::string* out) {
  std::lock_guard<std::mutex> lock(gMutex);
  auto it = gBytes.find(uri);
  if (it == gBytes.end()) return false;
  *out = it->second;
  return true;
}

void FetchBracket(std::function<void()>* begin, std::function<void()>* end) {
  std::lock_guard<std::mutex> lock(gMutex);
  if (begin) *begin = gBegin;
  if (end) *end = gEnd;
}

void SetFetcher(Fetcher fetch, std::function<void()> begin, std::function<void()> end) {
  std::lock_guard<std::mutex> lock(gMutex);
  gFetch = std::move(fetch);
  gBegin = std::move(begin);
  gEnd = std::move(end);
}

}  // namespace rni::image
