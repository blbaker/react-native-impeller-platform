#include "text/FontRegistry.h"
#include "base/TsanAnnotate.h"

#include "text/FontFamily.h"
#include "text/TypographyContexts.h"

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
  // FP-12: `typography` is this thread's context; fonts go into the process-wide
  // list so every thread's context (measure on JS, paint on main) registers them.
  if (typography::ForThisThread() != typography) {
    fprintf(stderr, "rn-impeller: RegisterFontDirs: context is not this thread's\n");
  }
  rni::tsan::NoteExclusiveUse(typography);  // FP-04: impeller.h typography contexts are single-thread
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
    NoteAppFontDir(dir);
    for (const auto& path : files) {
      std::ifstream in(path, std::ios::binary);
      std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)),
                                 std::istreambuf_iterator<char>());
      bool ok = false;
      if (!bytes.empty()) {
        const size_t index = typography::AddFont(
            path, std::make_shared<const std::vector<uint8_t>>(std::move(bytes)));
        ok = typography::RegisteredHere(index);
      }
      if (ok) ++registered;
      printf("rn-impeller: font_registered=%s ok=%d\n", path.c_str(), ok ? 1 : 0);
    }
  }
  fflush(stdout);
  return registered;
}

}  // namespace rni
