// Engine <-> web helper wire protocol (header-only, no dependencies).
//
// The web view's browser engine (WPE WebKit) does NOT live in rn-impeller's
// process. It runs in `rni-webhelper` (engine/webview/helper), a small program
// linked against libWPEWebKit-2.0, so the engine binary needs no GLib, no
// WebKit and no CDM, a renderer crash cannot take the app down, and the same
// engine binary runs on a box where WebKit lives in a container (WSL) or in
// the device image (Yocto meta-webkit).
//
// Transport: one AF_UNIX SOCK_SEQPACKET connection (message boundaries kept,
// fds passed with SCM_RIGHTS). The engine listens; the helper connects.
// Frames travel through a memfd the helper creates per view (3 RGBA slots,
// premultiplied, top row first: the ExternalFrame contract). Pixels never go
// through the socket; FRAME names a slot and the engine answers RELEASE_SLOT
// once it has copied it, so a slot is never rewritten while it is being read.
//
// Message = Header + nfields x (uint32 length + bytes). Numbers are decimal
// text: the protocol is debuggable with strace and costs nothing measurable
// next to a 3.6 MB frame copy.
#pragma once

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace rni::webproto {

constexpr uint32_t kMagic = 0x56574e52;  // "RNWV"
constexpr int kVersion = 1;
constexpr int kSlots = 3;

enum Type : uint16_t {
  // engine -> helper
  kCreate = 1,      // view; fields: width, height, scale, userAgent
  kLoad = 2,        // view; url, headers ("name\nvalue\n..." top-level request only)
  kResize = 3,      // view; width, height, scale (logical px + device scale)
  kNav = 4,         // view; "back" | "forward" | "reload" | "stop"
  kInject = 5,      // view; js (run now, top frame)
  kUserScript = 6,  // view; js, "end" | "start" (re-run on every page; "" clears)
  kPointer = 7,     // view; "move"|"down"|"up"|"enter"|"leave", button, x, y, mods, clicks
  kTouch = 8,       // view; "down"|"move"|"up"|"cancel", x, y, mods
  kScroll = 9,      // view; x, y, dx, dy, mods   (dx/dy in CSS px, positive = content moves up/left)
  kKey = 10,        // view; "down"|"up", keyval, keycode, mods
  kFocus = 11,      // view; "1" | "0"
  kDestroy = 12,    // view
  kReleaseSlot = 13,  // view; generation, slot
  kClearData = 14,  // (no view) cookies, storage, cache: member sign-out
  kQuit = 15,
  // view; text (UTF-8). An input method commit into the focused editable: the app
  // draws its own keyboard (the device has no OS input method). Added in v1: a
  // new kind, no existing message changed, so an older helper logs "unknown
  // message type 16" and drops it.
  kText = 16,
  // helper -> engine
  kReady = 101,  // version, webkitVersion, eme ("1"/"0"), cdm (OCDM_WIDEVINE_CDM or "")
  kFrame = 102,  // view; generation, slot, width, height, seq   (+ memfd when generation is new)
  // view; type, json   (loadStart | load | loadEnd | error | navState | console |
  // editableFocus {focused, isPassword, purpose})
  kEvent = 103,
};

// Modifier bits shared by both ends (the helper maps them to WPE_MODIFIER_*).
enum Mods : uint32_t { kShift = 1, kCtrl = 2, kAlt = 4, kMeta = 8, kCaps = 16, kButton1 = 256 };

struct Header {
  uint32_t magic;
  uint16_t type;
  uint16_t nfields;
  uint32_t view;
};

class Writer {
 public:
  Writer(uint16_t type, uint32_t view) {
    Header h{kMagic, type, 0, view};
    buf_.assign(reinterpret_cast<const char*>(&h), sizeof h);
  }
  Writer& str(const std::string& s) {
    const uint32_t n = (uint32_t)s.size();
    buf_.append(reinterpret_cast<const char*>(&n), sizeof n);
    buf_.append(s);
    reinterpret_cast<Header*>(&buf_[0])->nfields++;
    return *this;
  }
  Writer& num(double v) {
    char tmp[48];
    snprintf(tmp, sizeof tmp, "%.17g", v);
    return str(tmp);
  }
  const std::string& bytes() const { return buf_; }

 private:
  std::string buf_;
};

struct Message {
  uint16_t type = 0;
  uint32_t view = 0;
  std::vector<std::string> f;
  int fd = -1;  // SCM_RIGHTS fd, owned by the receiver
  const std::string& s(size_t i) const {
    static const std::string empty;
    return i < f.size() ? f[i] : empty;
  }
  double d(size_t i) const { return i < f.size() ? strtod(f[i].c_str(), nullptr) : 0.0; }
  long long i(size_t k) const { return k < f.size() ? strtoll(f[k].c_str(), nullptr, 10) : 0; }
};

// False on a malformed packet (wrong magic, truncated field).
inline bool Parse(const char* p, size_t n, Message* out) {
  if (n < sizeof(Header)) return false;
  Header h;
  memcpy(&h, p, sizeof h);
  if (h.magic != kMagic) return false;
  out->type = h.type;
  out->view = h.view;
  out->f.clear();
  size_t off = sizeof h;
  for (uint16_t k = 0; k < h.nfields; ++k) {
    uint32_t len;
    if (off + sizeof len > n) return false;
    memcpy(&len, p + off, sizeof len);
    off += sizeof len;
    if (off + len > n) return false;
    out->f.emplace_back(p + off, len);
    off += len;
  }
  return true;
}

// "name\nvalue\nname\nvalue" <-> pairs. HTTP forbids CR/LF in both.
inline std::string JoinHeaders(const std::vector<std::pair<std::string, std::string>>& h) {
  std::string out;
  for (auto& [k, v] : h) {
    if (k.find_first_of("\r\n") != std::string::npos || v.find_first_of("\r\n") != std::string::npos)
      continue;
    out += k;
    out += '\n';
    out += v;
    out += '\n';
  }
  return out;
}

inline std::vector<std::pair<std::string, std::string>> SplitHeaders(const std::string& s) {
  std::vector<std::pair<std::string, std::string>> out;
  size_t pos = 0;
  while (pos < s.size()) {
    const size_t a = s.find('\n', pos);
    if (a == std::string::npos) break;
    const size_t b = s.find('\n', a + 1);
    if (b == std::string::npos) break;
    out.emplace_back(s.substr(pos, a - pos), s.substr(a + 1, b - a - 1));
    pos = b + 1;
  }
  return out;
}

// Largest message either side sends or accepts. An AF_UNIX SEQPACKET datagram
// must fit the sender's SO_SNDBUF, which an unprivileged process cannot raise
// past net.core.wmem_max (212992 by default). Injected scripts are the big
// ones; a larger one is refused with an onError, never silently cut.
constexpr size_t kMaxPacket = 196608;

}  // namespace rni::webproto
