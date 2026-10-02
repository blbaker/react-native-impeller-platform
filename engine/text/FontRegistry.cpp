#include "text/FontRegistry.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>

namespace rni {
namespace {

bool HasFontExtension(const std::string& name) {
  auto dot = name.rfind('.');
  if (dot == std::string::npos) return false;
  std::string ext = name.substr(dot + 1);
  std::transform(ext.begin(), ext.end(), ext.begin(),
                 [](unsigned char c) { return (char)std::tolower(c); });
  return ext == "ttf" || ext == "otf" || ext == "ttc";
}

// Impeller keeps the bytes until it calls on_release. Its release lambda may
// also read the ImpellerMapping itself at that point (it can capture the
// `contents` pointer), so the mapping lives on the heap NEXT TO the bytes and
// both are freed only by that callback.
struct FontBlob {
  std::vector<uint8_t> bytes;
  ImpellerMapping mapping{};
};

void ReleaseFontBlob(void* userData) {
  delete static_cast<FontBlob*>(userData);
}

}  // namespace

std::vector<std::string> FontDirsFrom(const std::vector<std::string>& cliDirs) {
  std::vector<std::string> dirs = cliDirs;
  if (const char* env = std::getenv("RNI_FONT_DIRS")) {
    std::string all = env;
    size_t start = 0;
#if defined(_WIN32)
    const char sep = ';';  // C:\fonts would split on ':'
#else
    const char sep = ':';
#endif
    while (start <= all.size()) {
      size_t colon = all.find(sep, start);
      std::string part = all.substr(
          start, colon == std::string::npos ? std::string::npos : colon - start);
      if (!part.empty()) dirs.push_back(part);
      if (colon == std::string::npos) break;
      start = colon + 1;
    }
  }
  return dirs;
}

int RegisterFontDirs(ImpellerTypographyContext typography,
                     const std::vector<std::string>& dirs) {
  if (typography == nullptr) return 0;
  int registered = 0;
  for (const auto& dir : dirs) {
    // std::filesystem, not dirent.h: the same file builds for win32-x64.
    std::error_code ec;
    std::filesystem::directory_iterator it(dir, ec);
    if (ec) {
      fprintf(stderr, "rn-impeller: font dir not readable: %s\n", dir.c_str());
      continue;
    }
    // Sorted, so registration order (and so which face wins a duplicate
    // family) does not depend on directory order.
    std::vector<std::string> files;
    for (const auto& entry : it) {
      if (!entry.is_regular_file(ec)) continue;
      if (HasFontExtension(entry.path().filename().string())) {
        files.push_back(entry.path().string());
      }
    }
    std::sort(files.begin(), files.end());
    for (const auto& path : files) {
      std::ifstream in(path, std::ios::binary);
      std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)),
                                 std::istreambuf_iterator<char>());
      bool ok = false;
      if (!bytes.empty()) {
        auto* blob = new FontBlob();
        blob->bytes = std::move(bytes);
        blob->mapping.data = blob->bytes.data();
        blob->mapping.length = blob->bytes.size();
        blob->mapping.on_release = &ReleaseFontBlob;
        // Ownership passes to Impeller here, success or not: a rejected
        // mapping is released through the same callback, so never free the
        // blob on this side.
        ok = ImpellerTypographyContextRegisterFont(typography, &blob->mapping,
                                                   blob, nullptr);
      }
      if (ok) ++registered;
      printf("rn-impeller: font_registered=%s ok=%d\n", path.c_str(), ok ? 1 : 0);
    }
  }
  fflush(stdout);
  return registered;
}

}  // namespace rni
