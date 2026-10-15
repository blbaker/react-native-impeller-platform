#pragma once

// FP-16: pieces ImageStore.cpp shares with ImageDecode.cpp and ImageFetch.cpp.

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

#include "ImageStore.h"

namespace rni::image {

// ImageDecode.cpp. Every decode goes through RunDecode: it counts decodes and
// the most ever running at once (PeakLiveDecodes), and applies the test hooks
// RNI_TEST_IMAGE_DECODE_DELAY_MS, RNI_IMAGE_LOG and RNI_TEST_IMAGE_DUMP.
std::shared_ptr<const Decoded> RunDecode(const uint8_t* data, size_t n, int boxW, int boxH,
                                         const std::string& uri);
int DecodeCount();
int PeakLiveDecodes();
int EnvInt(const char* name);

// ImageFetch.cpp. One GET per URI however many sizes want it; fetched bodies
// are kept (32 MB cap) so another size decodes without a second GET.
FetchResult FetchShared(const std::string& uri, const Headers& headers);
bool CachedBody(const std::string& uri, std::string* out);
void ClearFetchedBodies();
void FetchBracket(std::function<void()>* begin, std::function<void()>* end);

}  // namespace rni::image
