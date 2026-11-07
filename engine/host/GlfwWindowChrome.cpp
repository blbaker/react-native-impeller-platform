// ENG-54: the window's own chrome. A bare rn-impeller window showed GLFW's
// default icon and, on Windows, a light title bar over a dark app; Jim.exe
// patched both from outside (WM_SETICON, DWM) once the window existed.
#include "host/GlfwSurface.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>
#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#define GLFW_EXPOSE_NATIVE_WIN32
#include <GLFW/glfw3native.h>
#include <dwmapi.h>
// Named by newer Windows SDKs only (Windows 10 20H1 and later); the value is
// the documented attribute id.
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#endif

// Declarations only: the PNG decoder is compiled once, in fabric/ImageDecode.cpp.
#include "third_party/stb/stb_image.h"

namespace rni {

namespace {

bool HasExtension(const std::string& path, const std::string& ext) {
  if (path.size() < ext.size()) return false;
  std::string tail = path.substr(path.size() - ext.size());
  std::transform(tail.begin(), tail.end(), tail.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return tail == ext;
}

// Returns "" on success, else the reason.
std::string SetPngIcon(GLFWwindow* window, const std::string& path, int* w, int* h) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return "cannot read the file";
  const std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(in)),
                                         std::istreambuf_iterator<char>());
  int comp = 0;
  unsigned char* rgba =
      stbi_load_from_memory(bytes.data(), (int)bytes.size(), w, h, &comp, 4);
  if (rgba == nullptr) return std::string("not a decodable image: ") + stbi_failure_reason();
  GLFWimage image{*w, *h, rgba};
  glfwGetError(nullptr);
  glfwSetWindowIcon(window, 1, &image);  // GLFW copies the pixels
  stbi_image_free(rgba);
  const char* why = nullptr;
  if (glfwGetError(&why) != GLFW_NO_ERROR) return why != nullptr ? why : "glfwSetWindowIcon failed";
  return "";
}

#if defined(_WIN32)
std::wstring Widen(const std::string& s) {
  if (s.empty()) return {};
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring out((size_t)n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), n);
  return out;
}

// An .ico carries its own sizes; Windows picks the big (taskbar, Alt+Tab) and
// small (title bar) entries. The icons live as long as the window, which is
// the process, so they are not destroyed.
std::string SetIcoIcon(GLFWwindow* window, const std::string& path) {
  const HWND hwnd = glfwGetWin32Window(window);
  if (hwnd == nullptr) return "no native window";
  const std::wstring wpath = Widen(path);
  const HICON bigIcon = static_cast<HICON>(
      LoadImageW(nullptr, wpath.c_str(), IMAGE_ICON, GetSystemMetrics(SM_CXICON),
                 GetSystemMetrics(SM_CYICON), LR_LOADFROMFILE));
  const DWORD bigError = GetLastError();
  const HICON smallIcon = static_cast<HICON>(
      LoadImageW(nullptr, wpath.c_str(), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                 GetSystemMetrics(SM_CYSMICON), LR_LOADFROMFILE));
  if (bigIcon == nullptr || smallIcon == nullptr) {
    if (bigIcon != nullptr) DestroyIcon(bigIcon);
    if (smallIcon != nullptr) DestroyIcon(smallIcon);
    return "LoadImageW failed (error " +
           std::to_string(bigIcon == nullptr ? bigError : GetLastError()) + ")";
  }
  SendMessageW(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(bigIcon));
  SendMessageW(hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(smallIcon));
  return "";
}
#endif

}  // namespace

void GlfwSurface::applyChrome(const std::string& iconPath, bool darkTitleBar) {
  if (window_ == nullptr) return;
  if (!iconPath.empty()) {
    std::string error;
    int w = 0, h = 0;
    if (HasExtension(iconPath, ".ico")) {
#if defined(_WIN32)
      error = SetIcoIcon(window_, iconPath);
#else
      error = ".ico is Windows-only; pass a .png";
#endif
    } else {
      error = SetPngIcon(window_, iconPath, &w, &h);
    }
    if (error.empty()) {
      std::printf("rn-impeller: window_icon=%s ok=1 size=%dx%d\n", iconPath.c_str(), w, h);
    } else {
      std::printf("rn-impeller: window_icon=%s ok=0 error=%s\n", iconPath.c_str(), error.c_str());
    }
  }
#if defined(_WIN32)
  if (darkTitleBar) {
    const HWND hwnd = glfwGetWin32Window(window_);
    const BOOL on = TRUE;
    const HRESULT hr =
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &on, sizeof(on));
    // The frame was already painted light; repaint it with the new colour.
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    std::printf("rn-impeller: title_bar dark=1 hr=0x%08lx\n", (unsigned long)hr);
  }
#else
  (void)darkTitleBar;
#endif
  std::fflush(stdout);
}

}  // namespace rni
