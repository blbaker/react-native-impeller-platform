// rni-webhelper frames: WPE "buffer-rendered" -> premultiplied RGBA in a memfd
// slot -> FRAME message. The engine copies the slot and answers RELEASE_SLOT, so
// a slot is never rewritten mid-read. With every slot held, the newest frame
// waits as `pending` and is written the moment one frees: a static page's LAST
// frame must never be dropped, or the engine would show a stale page forever.
#include <sys/mman.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>

#include "helper.h"

namespace rniweb {
namespace wp = rni::webproto;
namespace {

bool Ensure(FrameSlots* f, int w, int h) {
  if (f->map && f->width == w && f->height == h) return true;
  FreeFrames(f);
  f->slotBytes = (size_t)w * h * 4;
  f->fd = memfd_create("rni-webview-frames", MFD_CLOEXEC);
  if (f->fd < 0 || ftruncate(f->fd, (off_t)(f->slotBytes * wp::kSlots)) != 0) {
    perror("rni-webhelper: memfd");
    FreeFrames(f);
    return false;
  }
  void* p = mmap(nullptr, f->slotBytes * wp::kSlots, PROT_READ | PROT_WRITE, MAP_SHARED, f->fd, 0);
  if (p == MAP_FAILED) {
    perror("rni-webhelper: mmap");
    FreeFrames(f);
    return false;
  }
  f->map = static_cast<uint8_t*>(p);
  f->width = w;
  f->height = h;
  ++f->generation;
  f->sentFd = false;
  for (bool& b : f->busy) b = false;
  return true;
}

// WPE SHM is ARGB8888 little-endian = B,G,R,A bytes, already premultiplied
// (WebKit composites premultiplied). The engine contract is premultiplied RGBA.
void Write(View* v, GBytes* bytes, int w, int h, int stride) {
  FrameSlots* f = &v->frames;
  if (!Ensure(f, w, h)) return;
  int slot = -1;
  for (int k = 0; k < wp::kSlots; ++k)
    if (!f->busy[k]) { slot = k; break; }
  if (slot < 0) {  // engine still holds all three: keep the newest for later
    if (f->pending) { g_bytes_unref(f->pending); ++f->dropped; }
    f->pending = g_bytes_ref(bytes);
    f->pendingW = w; f->pendingH = h; f->pendingStride = stride;
    return;
  }
  gsize len = 0;
  auto* src = static_cast<const uint8_t*>(g_bytes_get_data(bytes, &len));
  if ((size_t)stride * h > len) return;
  uint8_t* dst = f->map + f->slotBytes * slot;
  for (int y = 0; y < h; ++y) {
    const uint8_t* s = src + (size_t)y * stride;
    uint8_t* d = dst + (size_t)y * w * 4;
    for (int x = 0; x < w; ++x, s += 4, d += 4) {
      d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; d[3] = s[3];
    }
  }
  f->busy[slot] = true;
  ++f->seq;
  wp::Writer m(wp::kFrame, v->id);
  m.num(f->generation).num(slot).num(w).num(h).num((double)f->seq);
  const bool withFd = !f->sentFd;
  Send(m, withFd ? f->fd : -1);
  f->sentFd = true;
  if (H().log && (f->seq <= 3 || f->seq % 120 == 0))
    printf("rni-webhelper: frame view=%u seq=%llu %dx%d gen=%u slot=%d fd=%d\n", v->id,
           (unsigned long long)f->seq, w, h, f->generation, slot, withFd ? 1 : 0);
}

}  // namespace

void OnBuffer(View* v, WPEBuffer* buffer) {
  GError* err = nullptr;
  GBytes* bytes = wpe_buffer_import_to_pixels(buffer, &err);
  if (!bytes) {
    fprintf(stderr, "rni-webhelper: import_to_pixels failed: %s\n", err ? err->message : "?");
    if (err) g_error_free(err);
    return;
  }
  const int w = wpe_buffer_get_width(buffer), h = wpe_buffer_get_height(buffer);
  const int stride =
      WPE_IS_BUFFER_SHM(buffer) ? (int)wpe_buffer_shm_get_stride(WPE_BUFFER_SHM(buffer)) : w * 4;
  if (w > 0 && h > 0) Write(v, bytes, w, h, stride);
}

void ReleaseSlot(View* v, uint32_t generation, int slot) {
  FrameSlots* f = &v->frames;
  if (generation != f->generation || slot < 0 || slot >= wp::kSlots) return;
  f->busy[slot] = false;
  if (f->pending) {
    GBytes* b = f->pending;
    f->pending = nullptr;
    Write(v, b, f->pendingW, f->pendingH, f->pendingStride);
    g_bytes_unref(b);
  }
}

void FreeFrames(FrameSlots* f) {
  if (f->map) munmap(f->map, f->slotBytes * wp::kSlots);
  if (f->fd >= 0) close(f->fd);
  if (f->pending) g_bytes_unref(f->pending);
  f->map = nullptr;
  f->fd = -1;
  f->pending = nullptr;
}

}  // namespace rniweb
