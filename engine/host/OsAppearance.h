#pragma once

// The OS light/dark setting, and a thread that reports when it changes.
//
// Test hook: RNI_OS_APPEARANCE_FILE names a file holding "light" or "dark"
// (polled), RNI_OS_APPEARANCE is a fixed value. When either is set the real OS
// is never read, so gates cannot depend on (or touch) the developer's theme.
#include <atomic>
#include <functional>
#include <string>
#include <thread>

namespace rni {

// "light", "dark", or "" when the hook is unset/unreadable and (if allowed)
// the OS gave no answer.
std::string ResolveSystemScheme(bool allowRealOs);
bool OsAppearanceHookActive();

// Real OS only: darwin NSApp effectiveAppearance, linux xdg-desktop-portal then
// gsettings, win32 AppsUseLightTheme. "" when unknown.
std::string ReadRealOsScheme();

class OsAppearanceWatcher {
 public:
  using Callback = std::function<void(const std::string&)>;
  OsAppearanceWatcher(std::string initial, bool allowRealOs, Callback onChange);
  ~OsAppearanceWatcher();
  OsAppearanceWatcher(const OsAppearanceWatcher&) = delete;
  OsAppearanceWatcher& operator=(const OsAppearanceWatcher&) = delete;

 private:
  std::atomic<bool> stop_{false};
  std::thread thread_;
};

#ifdef __APPLE__
std::string DarwinOsScheme();      // OsAppearanceDarwin.mm, main thread only
void DarwinRefreshOsScheme();      // any thread: re-reads on the main queue
std::string DarwinCachedOsScheme();
#endif

}  // namespace rni
