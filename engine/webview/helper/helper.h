// rni-webhelper: hosts WPE WebKit views for rn-impeller (see ../WebViewProtocol.h).
#pragma once

#include <wpe/webkit.h>
#include <wpe/wpe-platform.h>

#include <cstdint>
#include <map>
#include <memory>
#include <string>

#include "../WebViewProtocol.h"

namespace rniweb {

struct View;

struct Helper {
  int sock = -1;
  GMainLoop* loop = nullptr;
  WebKitNetworkSession* session = nullptr;
  WPEDisplay* display = nullptr;
  std::map<uint32_t, std::unique_ptr<View>> views;
  bool log = false;  // RNI_WEBHELPER_LOG=1
};

Helper& H();
void Send(const rni::webproto::Writer& w, int fd = -1);
void SendEvent(uint32_t view, const std::string& type, const std::string& json);
std::string JsonEscape(const std::string& s);

// Frames: a memfd with kSlots RGBA slots per view (frames.cpp).
struct FrameSlots {
  int fd = -1;
  uint8_t* map = nullptr;
  size_t slotBytes = 0;
  int width = 0, height = 0;
  uint32_t generation = 0;
  bool sentFd = false;
  bool busy[rni::webproto::kSlots] = {false, false, false};
  GBytes* pending = nullptr;  // newest frame waiting for a free slot
  int pendingW = 0, pendingH = 0, pendingStride = 0;
  uint64_t seq = 0, dropped = 0;
};

struct View {
  uint32_t id = 0;
  WebKitWebView* web = nullptr;
  WPEView* wpe = nullptr;
  WebKitUserContentManager* ucm = nullptr;
  WebKitInputMethodContext* im = nullptr;  // the app-keyboard context (input.cpp), owned
  std::string scriptEnd, scriptStart;
  FrameSlots frames;
  bool failed = false;     // load-failed seen for the current navigation
  bool touchDown = false;
  double scale = 1;
};

View* CreateView(uint32_t id, int w, int h, double scale, const std::string& ua);
void DestroyView(View* v);  // releases v's WebKit objects + frames; H().views frees v
void LoadUrl(View* v, const std::string& url, const std::string& headers);
void SetUserScripts(View* v);
void OnBuffer(View* v, WPEBuffer* buffer);
void ReleaseSlot(View* v, uint32_t generation, int slot);
void FreeFrames(FrameSlots* f);
void HandleInput(View* v, const rni::webproto::Message& m);
// Installs / releases v's input method context: editableFocus events + kText commits.
void InstallInputMethod(View* v);
void ReleaseInputMethod(View* v);

}  // namespace rniweb
