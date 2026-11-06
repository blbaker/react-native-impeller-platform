#include "webview/WebViewInput.h"

#include <cstdio>
#include <cstdlib>

#include "scenegraph/SceneGraph.h"
#include "webview/WebViewHost.h"
#include "webview/WebViewProtocol.h"

namespace rni {
namespace {

WebViewHost& H() { return WebViewHost::Instance(); }

void Log(const char* what, int64_t id, float x, float y) {
  printf("rn-impeller: webview_input %s id=%lld at=%.1f,%.1f\n", what, (long long)id, x, y);
  fflush(stdout);
}

// Single UTF-8 codepoint, or 0 when `s` is longer (a named key like "Enter").
unsigned SingleCodepoint(const std::string& s) {
  if (s.empty()) return 0;
  const unsigned char c = (unsigned char)s[0];
  const size_t len = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 0;
  if (!len || s.size() != len) return 0;
  unsigned cp = len == 1 ? c : len == 2 ? (c & 0x1f) : len == 3 ? (c & 0x0f) : (c & 0x07);
  for (size_t i = 1; i < len; ++i) cp = (cp << 6) | ((unsigned char)s[i] & 0x3f);
  return cp;
}

}  // namespace

uint32_t WebViewInput::Mods(bool shift, bool ctrl, bool alt, bool meta, bool caps) {
  return (shift ? webproto::kShift : 0) | (ctrl ? webproto::kCtrl : 0) | (alt ? webproto::kAlt : 0) |
         (meta ? webproto::kMeta : 0) | (caps ? webproto::kCaps : 0);
}

uint32_t WebViewInput::KeysymForCodepoint(unsigned cp) {
  if (cp >= 0x20 && cp < 0x7f) return cp;
  if (cp >= 0xa0 && cp <= 0xff) return cp;
  return cp ? 0x01000000u | cp : 0;
}

uint32_t WebViewInput::KeysymForKey(const std::string& key) {
  struct Entry { const char* name; uint32_t sym; };
  static const Entry kTable[] = {
      {"Enter", 0xff0d},     {"Tab", 0xff09},       {"Backspace", 0xff08}, {"Escape", 0xff1b},
      {"Delete", 0xffff},    {"Insert", 0xff63},    {"Home", 0xff50},      {"End", 0xff57},
      {"PageUp", 0xff55},    {"PageDown", 0xff56},  {"ArrowLeft", 0xff51}, {"ArrowUp", 0xff52},
      {"ArrowRight", 0xff53}, {"ArrowDown", 0xff54}, {"Shift", 0xffe1},    {"Control", 0xffe3},
      {"Alt", 0xffe9},       {"Meta", 0xffeb},      {"CapsLock", 0xffe5},  {"ContextMenu", 0xff67},
  };
  for (const auto& e : kTable)
    if (key == e.name) return e.sym;
  if (key.size() >= 2 && key[0] == 'F') {  // F1..F24
    const int n = atoi(key.c_str() + 1);
    if (n >= 1 && n <= 24) return 0xffbe + (uint32_t)(n - 1);
  }
  return 0;
}

bool WebViewInput::HitWeb(float x, float y, int64_t* id, float* lx, float* ly) {
  if (!sg_) return false;
  SceneGraph::TextureViewHit hit;
  if (!sg_->textureViewAt(x, y, &hit) || !H().IsWebView(hit.textureId)) return false;
  *id = hit.textureId;
  *lx = x - hit.x;
  *ly = y - hit.y;
  return true;
}

bool WebViewInput::MouseButton(float x, float y, bool down, int w3cButton, uint32_t mods, int clicks) {
  if (w3cButton == 0) {
    if (!down) {
      if (!capture_) return false;
      const int64_t id = capture_;
      capture_ = 0;
      H().Touch(id, "up", x - capX_, y - capY_, mods);
      Log("touch_up", id, x - capX_, y - capY_);
      return true;
    }
    int64_t id;
    float lx, ly;
    if (!HitWeb(x, y, &id, &lx, &ly)) {
      // Blurs the focused view unless the app holds it for its keyboard (setKeepFocus).
      if (const int64_t kept = H().PressOutside()) Log("keep_focus", kept, x, y);
      return false;
    }
    H().SetFocused(id);
    capture_ = id;
    capX_ = x - lx;  // the view's origin at the press: the whole drag is relative to it
    capY_ = y - ly;
    H().Touch(id, "down", lx, ly, mods | webproto::kButton1);
    Log("touch_down", id, lx, ly);
    return true;
  }
  int64_t id;
  float lx, ly;
  if (!HitWeb(x, y, &id, &lx, &ly)) return false;
  // W3C 1 middle / 2 right / 3 back / 4 forward -> WPE 2 middle / 3 secondary / 8 / 9.
  const int wpeButton = w3cButton == 1 ? 2 : w3cButton == 2 ? 3 : w3cButton == 3 ? 8 : 9;
  H().Pointer(id, down ? "down" : "up", wpeButton, lx, ly, mods, clicks);
  Log(down ? "button_down" : "button_up", id, lx, ly);
  return true;
}

bool WebViewInput::MouseMove(float x, float y, uint32_t mods) {
  if (capture_) {
    H().Touch(capture_, "move", x - capX_, y - capY_, mods | webproto::kButton1);
    return true;
  }
  int64_t id = 0;
  float lx = 0, ly = 0;
  const bool hit = HitWeb(x, y, &id, &lx, &ly);
  if (hover_ && hover_ != id) {
    H().Pointer(hover_, "leave", 0, -1, -1, mods, 0);
    hover_ = 0;
  }
  if (!hit) return false;
  if (hover_ != id) {
    H().Pointer(id, "enter", 0, lx, ly, mods, 0);
    hover_ = id;
  }
  H().Pointer(id, "move", 0, lx, ly, mods, 0);
  return true;
}

bool WebViewInput::Scroll(float x, float y, float dx, float dy, uint32_t mods) {
  int64_t id;
  float lx, ly;
  if (!HitWeb(x, y, &id, &lx, &ly)) return false;
  H().Scroll(id, lx, ly, dx, dy, mods);
  printf("rn-impeller: webview_input scroll id=%lld at=%.1f,%.1f dx=%.1f dy=%.1f\n", (long long)id,
         lx, ly, dx, dy);
  fflush(stdout);
  return true;
}

int64_t WebViewInput::focused() const { return H().Focused(); }

bool WebViewInput::Key(const std::string& key, bool down, uint32_t mods) {
  const int64_t focus = H().Focused();
  if (!focus || !H().IsWebView(focus)) return false;
  uint32_t sym = KeysymForKey(key);
  if (!sym) {
    // Printable keys arrive as TEXT through Char() (layout + dead keys
    // honoured). Only a chord (Ctrl/Alt/Meta+key: copy, select-all) goes as a
    // key, since no character is typed for it.
    const unsigned cp = SingleCodepoint(key);
    if (!cp || !(mods & (webproto::kCtrl | webproto::kAlt | webproto::kMeta))) return true;
    sym = KeysymForCodepoint(cp >= 'A' && cp <= 'Z' ? cp + 32 : cp);
  }
  H().Key(focus, down, sym, 0, mods);
  return true;
}

bool WebViewInput::Char(unsigned codepoint, uint32_t mods) {
  const int64_t focus = H().Focused();
  if (!focus || !H().IsWebView(focus)) return false;
  const uint32_t sym = KeysymForCodepoint(codepoint);
  if (!sym) return true;
  H().Key(focus, true, sym, 0, mods);
  H().Key(focus, false, sym, 0, mods);
  return true;
}

void WebViewInput::CursorLeave() {
  if (hover_) H().Pointer(hover_, "leave", 0, -1, -1, 0, 0);
  hover_ = 0;
}

}  // namespace rni
