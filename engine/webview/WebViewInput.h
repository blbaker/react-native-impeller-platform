// Routes the window's mouse / wheel / keyboard to a web view when one is the
// topmost thing under the cursor (SceneGraph::textureViewAt). Called first by
// RunWindowed's GLFW handlers; a true return means the web view owns the event.
//
//   hover, right/middle buttons -> pointer events
//   left press .. drag .. release -> ONE touch sequence (WebKit's gesture
//     controller turns an unconsumed tap into a click and a drag into a
//     scroll, and pages with touch handlers get real touches: the device's
//     touchscreen behaviour on a mouse). The press captures the view, so a drag
//     that leaves its rect still belongs to it, like a real touch.
//   wheel over the view -> scroll (consumed: an RN ScrollView behind it stays put)
//   keys + typed characters -> the focused web view (focus = last press inside
//     one; a press anywhere else blurs it, except while the app keeps focus for
//     its own keyboard, and clearing that hold blurs it too: WebViewHost's
//     PressOutside / SetKeepFocus, ImpellerWebView.setKeepFocus)
#pragma once

#include <cstdint>
#include <string>

namespace rni {

class SceneGraph;

class WebViewInput {
 public:
  explicit WebViewInput(SceneGraph* sceneGraph) : sg_(sceneGraph) {}
  // Layout points (the space FabricHost dispatch uses). w3cButton: 0 left,
  // 1 middle, 2 right, 3 back, 4 forward.
  bool MouseButton(float x, float y, bool down, int w3cButton, uint32_t mods, int clicks);
  bool MouseMove(float x, float y, uint32_t mods);
  bool Scroll(float x, float y, float dx, float dy, uint32_t mods);
  bool Key(const std::string& key, bool down, uint32_t mods);
  bool Char(unsigned codepoint, uint32_t mods);
  void CursorLeave();
  int64_t focused() const;  // WebViewHost::Focused()
  bool capturing() const { return capture_ != 0; }
  static uint32_t Mods(bool shift, bool ctrl, bool alt, bool meta, bool caps = false);

  // W3C `key` -> XKB keysym (0 = not a key the page needs).
  static uint32_t KeysymForKey(const std::string& key);
  static uint32_t KeysymForCodepoint(unsigned cp);

 private:
  bool HitWeb(float x, float y, int64_t* id, float* lx, float* ly);

  SceneGraph* sg_;
  int64_t capture_ = 0;
  float capX_ = 0, capY_ = 0;
  int64_t hover_ = 0;
};

}  // namespace rni
