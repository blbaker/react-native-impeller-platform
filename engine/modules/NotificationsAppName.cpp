// AppDisplayName(): the sender name the Linux and Windows backends show.
#include "modules/Notifications.h"

#include <cstdlib>
#include <string>

#if defined(_WIN32)
#include <windows.h>
#elif defined(__APPLE__)
#include <mach-o/dyld.h>
#include <climits>
#else
#include <unistd.h>
#include <climits>
#endif

namespace rni::notifications {

namespace {

std::string ExecutablePath() {
#if defined(_WIN32)
  wchar_t wide[MAX_PATH];
  const DWORD n = GetModuleFileNameW(nullptr, wide, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return {};
  const int len = WideCharToMultiByte(CP_UTF8, 0, wide, (int)n, nullptr, 0,
                                      nullptr, nullptr);
  std::string out(len > 0 ? len : 0, '\0');
  if (len > 0) {
    WideCharToMultiByte(CP_UTF8, 0, wide, (int)n, out.data(), len, nullptr,
                        nullptr);
  }
  return out;
#elif defined(__APPLE__)
  char buf[PATH_MAX];
  uint32_t size = sizeof(buf);
  return _NSGetExecutablePath(buf, &size) == 0 ? std::string(buf) : std::string();
#else
  char buf[PATH_MAX];
  const ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
  return n > 0 ? std::string(buf, (size_t)n) : std::string();
#endif
}

}  // namespace

std::string AppDisplayName() {
  if (const char* name = std::getenv("RNI_APP_NAME"); name && *name) {
    return name;
  }
  std::string path = ExecutablePath();
  const size_t slash = path.find_last_of("/\\");
  if (slash != std::string::npos) path = path.substr(slash + 1);
  const size_t dot = path.rfind('.');
  if (dot != std::string::npos && dot > 0) path = path.substr(0, dot);
  return path.empty() ? std::string("rn-impeller") : path;
}

}  // namespace rni::notifications
