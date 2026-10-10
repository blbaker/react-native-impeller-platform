#include "host/OsAppearance.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>

#ifdef _WIN32
#include <windows.h>
#endif

namespace rni {

namespace {

std::string Trim(std::string s) {
  const char* ws = " \t\r\n'\"";
  const size_t b = s.find_first_not_of(ws);
  if (b == std::string::npos) return "";
  return s.substr(b, s.find_last_not_of(ws) - b + 1);
}

std::string Valid(const std::string& s) {
  return (s == "light" || s == "dark") ? s : "";
}

#if !defined(_WIN32)
std::string RunCapture(const char* cmd) {
  FILE* p = popen(cmd, "r");
  if (!p) return "";
  std::string out;
  char buf[256];
  while (fgets(buf, sizeof buf, p)) out += buf;
  pclose(p);
  return out;
}
#endif

#if !defined(_WIN32) && !defined(__APPLE__)
std::string LinuxScheme() {
  // org.freedesktop.appearance color-scheme: 1 = prefer dark, 2 = prefer light.
  const std::string portal = RunCapture(
      "gdbus call --session --dest org.freedesktop.portal.Desktop "
      "--object-path /org/freedesktop/portal/desktop "
      "--method org.freedesktop.portal.Settings.Read "
      "org.freedesktop.appearance color-scheme 2>/dev/null");
  const size_t at = portal.find("uint32 ");
  if (at != std::string::npos) {
    const char c = portal[at + 7];
    if (c == '1') return "dark";
    if (c == '2') return "light";
  }
  const std::string gs = Trim(RunCapture(
      "gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null"));
  if (gs == "prefer-dark") return "dark";
  if (gs == "prefer-light") return "light";
  return "";
}
#endif

}  // namespace

bool OsAppearanceHookActive() {
  return std::getenv("RNI_OS_APPEARANCE_FILE") || std::getenv("RNI_OS_APPEARANCE");
}

std::string ReadRealOsScheme() {
#if defined(_WIN32)
  DWORD v = 1, size = sizeof v;
  if (RegGetValueA(HKEY_CURRENT_USER,
                   "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                   "AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &v,
                   &size) != ERROR_SUCCESS)
    return "";
  return v == 0 ? "dark" : "light";
#elif defined(__APPLE__)
  return DarwinCachedOsScheme();
#else
  return LinuxScheme();
#endif
}

std::string ResolveSystemScheme(bool allowRealOs) {
  if (const char* f = std::getenv("RNI_OS_APPEARANCE_FILE")) {
    std::ifstream in(f);
    std::stringstream ss;
    ss << in.rdbuf();
    return Valid(Trim(ss.str()));
  }
  if (const char* e = std::getenv("RNI_OS_APPEARANCE")) return Valid(Trim(e));
  if (!allowRealOs) return "";
#ifdef __APPLE__
  return DarwinOsScheme();
#else
  return ReadRealOsScheme();
#endif
}

OsAppearanceWatcher::OsAppearanceWatcher(std::string initial, bool allowRealOs,
                                         Callback onChange) {
  thread_ = std::thread([this, last = std::move(initial), allowRealOs,
                         cb = std::move(onChange)]() mutable {
    const auto period = std::chrono::milliseconds(OsAppearanceHookActive() ? 100 : 1500);
    while (!stop_) {
#ifdef __APPLE__
      if (!OsAppearanceHookActive()) DarwinRefreshOsScheme();
      const std::string now = OsAppearanceHookActive()
                                  ? ResolveSystemScheme(false)
                                  : DarwinCachedOsScheme();
#else
      const std::string now = ResolveSystemScheme(allowRealOs);
#endif
      if (!now.empty() && now != last) {
        last = now;
        cb(now);
      }
      for (auto t = std::chrono::milliseconds(0); t < period && !stop_;
           t += std::chrono::milliseconds(50))
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
  });
}

OsAppearanceWatcher::~OsAppearanceWatcher() {
  stop_ = true;
  if (thread_.joinable()) thread_.join();
}

}  // namespace rni
