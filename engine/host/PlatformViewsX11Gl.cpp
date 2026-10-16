// FP-44: the linux X11 platform view embedder (see host/PlatformViewEmbedder.h).
// Model: FlutterPlatformViewsController.mm submitFrame + applyMutators: per
// frame, on the raster thread, every view gets its box, clip and z position
// from this frame's mutator stack, and each overlay is re-rendered with this
// frame's slice, before the background is presented.
//
// X11 objects live on the embedder's OWN Display connection (opened on the
// raster thread), never GLFW's: Xlib is not thread-safe and main pumps GLFW's
// connection. Window ids are server-global, so the children still nest under
// the GLFW window. Input is not selected on any child, so pointer events
// propagate to the GLFW window (a wheel over the native view still scrolls).
#include "host/PlatformViewEmbedder.h"

#include "host/GlfwSurface.h"

#if defined(__linux__) && !defined(__ANDROID__)
#include <dlfcn.h>

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <GLFW/glfw3.h>
#define GLFW_EXPOSE_NATIVE_X11
#include <GLFW/glfw3native.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>
#include <vector>

#include "host/PlatformViewProbeX11.h"
#endif

namespace rni {

#if defined(__linux__) && !defined(__ANDROID__)

unsigned long GlfwSurface::x11Window() const {
  return window_ != nullptr ? (unsigned long)glfwGetX11Window(window_) : 0ul;
}

namespace {

// libXext is loaded at run time (GLFW does the same for XShape): no new link
// dependency. Constants from X11/extensions/shape.h and X11/X.h.
using ShapeRectsFn = void (*)(Display*, Window, int, int, int, XRectangle*, int, int, int);
constexpr int kShapeBounding = 0, kShapeSet = 0, kYXBanded = 3;

int IgnoreXError(Display*, XErrorEvent*) { return 0; }

unsigned long PixelFor(const Visual* v, uint8_t r, uint8_t g, uint8_t b) {
  auto chan = [](unsigned long mask, uint8_t c) {
    if (mask == 0) return 0ul;
    const int shift = __builtin_ctzl(mask);
    const unsigned long max = mask >> shift;
    return ((unsigned long)std::lround(c * (double)max / 255.0) << shift) & mask;
  };
  return chan(v->red_mask, r) | chan(v->green_mask, g) | chan(v->blue_mask, b);
}

struct Native {
  Window clip = 0, content = 0, overlay = 0;
  EGLSurface ovSurf = EGL_NO_SURFACE;
  unsigned long pixel = ~0ul;
  bool clipMapped = false, ovMapped = false;
};

class X11Embedder final : public PlatformViewEmbedder {
 public:
  X11Embedder(GlfwSurface& surface, Window parent) : surface_(surface), parent_(parent) {
    XSetErrorHandler(IgnoreXError);  // main, before the raster thread uses X
  }

  void SubmitFrame(const std::shared_ptr<PlatformViewFrame>& frame, int present,
                   uint64_t frameNumber) override {
    if (!Ensure()) return;
    std::vector<Px> gl;
    if (pvprobe::Enabled()) surface_.readPixels(&gl);  // this frame's background
    std::shared_ptr<PlatformViewFrame> apply = frame;
    last_ = frame;
    Place(apply.get());
    RenderOverlays(apply.get());
    ++frames_;
    if (pvprobe::Enabled()) {
      std::vector<pvprobe::ViewState> states;
      if (apply) {
        for (const auto& v : apply->views) {
          auto it = views_.find(v.tag);
          if (it == views_.end()) continue;
          states.push_back({v.tag, it->second.clip, it->second.content, it->second.overlay,
                            it->second.ovMapped});
        }
      }
      pvprobe::BeforePresent(dpy_, parent_, gl, surface_.gpuWidth(), surface_.gpuHeight(),
                             present, frameNumber, states);
    }
  }

  void DidPresent(int present) override {
    if (dpy_ != nullptr && pvprobe::Enabled()) pvprobe::AfterPresent(dpy_, parent_, present);
  }

  void Teardown() override {
    if (dpy_ == nullptr) return;
    for (auto& [tag, nv] : views_) Destroy(nv);
    views_.clear();
    XSync(dpy_, False);
    XCloseDisplay(dpy_);
    dpy_ = nullptr;
  }

  void PrintSummary() const override {
    std::printf("rn-impeller: platform_views_summary embedder=x11 frames=%llu views_max=%zu "
                "overlay_draws=%llu created=%llu destroyed=%llu\n",
                (unsigned long long)frames_, viewsMax_, (unsigned long long)overlayDraws_,
                (unsigned long long)created_, (unsigned long long)destroyed_);
  }

 private:
  bool Ensure() {
    if (dpy_ != nullptr) return true;
    if (failed_) return false;
    dpy_ = XOpenDisplay(nullptr);
    XWindowAttributes wa{};
    if (dpy_ == nullptr || !XGetWindowAttributes(dpy_, parent_, &wa)) {
      std::printf("rn-impeller: platform_view_embedder ok=0 why=%s\n",
                  dpy_ == nullptr ? "XOpenDisplay" : "parent");
      failed_ = true;
      return false;
    }
    visual_ = wa.visual;
    depth_ = wa.depth;
    if (void* xext = dlopen("libXext.so.6", RTLD_LAZY | RTLD_LOCAL)) {
      shapeRects_ = (ShapeRectsFn)dlsym(xext, "XShapeCombineRectangles");
    }
    // The overlays use the window's EGL config, hence its visual.
    const auto& egl = surface_.eglWindow();
    EGLint id = 0, n = 0;
    eglQueryContext((EGLDisplay)egl.display, (EGLContext)egl.context, EGL_CONFIG_ID, &id);
    const EGLint attrs[] = {EGL_CONFIG_ID, id, EGL_NONE};
    eglChooseConfig((EGLDisplay)egl.display, attrs, &config_, 1, &n);
    std::printf("rn-impeller: platform_view_embedder ok=1 kind=x11 depth=%d egl_config=%d "
                "shape=%d\n",
                depth_, (int)id, shapeRects_ != nullptr ? 1 : 0);
    std::fflush(stdout);
    return true;
  }

  Window Child(Window parent, unsigned long pixel, bool withPixel) {
    XSetWindowAttributes a{};
    a.background_pixel = pixel;
    a.background_pixmap = None;
    const unsigned long mask = withPixel ? CWBackPixel : CWBackPixmap;
    ++created_;
    return XCreateWindow(dpy_, parent, 0, 0, 1, 1, 0, CopyFromParent, InputOutput,
                         CopyFromParent, mask, &a);
  }

  void Destroy(Native& nv) {
    const auto& egl = surface_.eglWindow();
    if (nv.ovSurf != EGL_NO_SURFACE) eglDestroySurface((EGLDisplay)egl.display, nv.ovSurf);
    if (nv.clip) XDestroyWindow(dpy_, nv.clip);  // the content window goes with it
    if (nv.overlay) XDestroyWindow(dpy_, nv.overlay);
    destroyed_ += (nv.clip ? 2 : 0) + (nv.overlay ? 1 : 0);
    nv = Native{};
  }

  // applyMutators: box + clip -> clip window (the visible part) holding the
  // content window (the whole box, offset); overlays sized to their rect.
  void Place(const PlatformViewFrame* frame) {
    std::map<int, bool> live;
    std::vector<Window> stack;  // top first (XRestackWindows)
    if (frame) {
      viewsMax_ = std::max(viewsMax_, frame->views.size());
      for (const auto& v : frame->views) {
        live[v.tag] = true;
        Native& nv = views_[v.tag];
        if (nv.clip == 0) {
          nv.clip = Child(parent_, 0, false);
          nv.content = Child(nv.clip, 0, true);
          XMapWindow(dpy_, nv.content);
        }
        const unsigned long px = PixelFor(visual_, v.r, v.g, v.b);
        if (px != nv.pixel) {
          nv.pixel = px;
          XSetWindowBackground(dpy_, nv.content, px);
          XClearWindow(dpy_, nv.content);
        }
        const PvRect vis = v.clipped ? v.box.Intersect(v.clip) : v.box;
        const long cl = std::lround(vis.l), ct = std::lround(vis.t);
        const long cr = std::lround(vis.r), cb = std::lround(vis.b);
        if (vis.Empty() || cr <= cl || cb <= ct) {
          if (nv.clipMapped) XUnmapWindow(dpy_, nv.clip);
          nv.clipMapped = false;
        } else {
          XMoveResizeWindow(dpy_, nv.clip, (int)cl, (int)ct, (unsigned)(cr - cl), (unsigned)(cb - ct));
          const long bl = std::lround(v.box.l), bt = std::lround(v.box.t);
          const long bw = std::max(1l, std::lround(v.box.r) - bl);
          const long bh = std::max(1l, std::lround(v.box.b) - bt);
          XMoveResizeWindow(dpy_, nv.content, (int)(bl - cl), (int)(bt - ct), (unsigned)bw,
                            (unsigned)bh);
          if (!nv.clipMapped) XMapWindow(dpy_, nv.clip);
          nv.clipMapped = true;
        }
        PlaceOverlay(nv, v);
        if (nv.ovMapped) stack.insert(stack.begin(), nv.overlay);
        stack.insert(stack.begin() + (nv.ovMapped ? 1 : 0), nv.clip);
      }
    }
    for (auto it = views_.begin(); it != views_.end();) {
      if (live.count(it->first)) {
        ++it;
        continue;
      }
      Destroy(it->second);
      it = views_.erase(it);
    }
    if (stack.size() > 1) XRestackWindows(dpy_, stack.data(), (int)stack.size());
    XSync(dpy_, False);
  }

  void PlaceOverlay(Native& nv, const PlatformViewParams& v) {
    const bool want = !v.overlay.Empty() && v.overlayList != nullptr;
    if (!want) {
      if (nv.ovMapped) XUnmapWindow(dpy_, nv.overlay);
      nv.ovMapped = false;
      return;
    }
    if (nv.overlay == 0) nv.overlay = Child(parent_, 0, false);
    XMoveResizeWindow(dpy_, nv.overlay, (int)v.overlay.l, (int)v.overlay.t,
                      (unsigned)(v.overlay.r - v.overlay.l), (unsigned)(v.overlay.b - v.overlay.t));
    if (!nv.ovMapped) XMapWindow(dpy_, nv.overlay);
    nv.ovMapped = true;
  }

  // The iOS overlay pass: the slice into the overlay's own surface over
  // transparent; the window is shaped to the pixels it drew.
  void RenderOverlays(const PlatformViewFrame* frame) {
    if (frame == nullptr) return;
    const auto& egl = surface_.eglWindow();
    const auto dpy = (EGLDisplay)egl.display;
    bool switched = false;
    for (const auto& v : frame->views) {
      Native& nv = views_[v.tag];
      if (!nv.ovMapped) continue;
      if (nv.ovSurf == EGL_NO_SURFACE) {
        nv.ovSurf = eglCreateWindowSurface(dpy, config_, (EGLNativeWindowType)nv.overlay, nullptr);
        if (nv.ovSurf == EGL_NO_SURFACE) continue;
      }
      if (eglMakeCurrent(dpy, nv.ovSurf, nv.ovSurf, (EGLContext)egl.context) != EGL_TRUE) continue;
      switched = true;
      eglSwapInterval(dpy, 0);
      const int w = (int)(v.overlay.r - v.overlay.l), h = (int)(v.overlay.b - v.overlay.t);
      const ImpellerISize size = {w, h};
      ImpellerSurface s = ImpellerSurfaceCreateWrappedFBONew(surface_.context(), 0u,
                                                             kImpellerPixelFormatRGBA8888, &size);
      if (s == nullptr) continue;
      ImpellerSurfaceDrawDisplayList(s, v.overlayList);
      glFinish();
      ImpellerSurfaceRelease(s);
      Shape(nv.overlay, w, h);
      eglSwapBuffers(dpy, nv.ovSurf);
      ++overlayDraws_;
    }
    if (switched) {
      eglMakeCurrent(dpy, (EGLSurface)egl.surface, (EGLSurface)egl.surface,
                     (EGLContext)egl.context);
    }
  }

  // ShapeBounding = the rows' runs of drawn pixels (alpha >= 128).
  void Shape(Window win, int w, int h) {
    if (shapeRects_ == nullptr) return;
    std::vector<uint8_t> px((size_t)w * h * 4);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px.data());
    std::vector<XRectangle> rects;
    for (int y = 0; y < h; ++y) {
      const uint8_t* row = px.data() + (size_t)(h - 1 - y) * w * 4;  // GL rows are bottom-up
      for (int x = 0; x < w;) {
        if (row[x * 4 + 3] < 128) {
          ++x;
          continue;
        }
        const int x0 = x;
        while (x < w && row[x * 4 + 3] >= 128) ++x;
        rects.push_back(XRectangle{(short)x0, (short)y, (unsigned short)(x - x0), 1});
      }
    }
    shapeRects_(dpy_, win, kShapeBounding, 0, 0, rects.data(), (int)rects.size(), kShapeSet,
                kYXBanded);
    XSync(dpy_, False);
  }

  GlfwSurface& surface_;
  Window parent_;
  Display* dpy_ = nullptr;
  bool failed_ = false;
  Visual* visual_ = nullptr;
  int depth_ = 0;
  EGLConfig config_ = nullptr;
  ShapeRectsFn shapeRects_ = nullptr;
  std::map<int, Native> views_;
  std::shared_ptr<PlatformViewFrame> last_;
  uint64_t frames_ = 0, overlayDraws_ = 0, created_ = 0, destroyed_ = 0;
  size_t viewsMax_ = 0;
};

}  // namespace

std::unique_ptr<PlatformViewEmbedder> MakePlatformViewEmbedder(GlfwSurface& surface) {
  if (glfwGetPlatform() != GLFW_PLATFORM_X11 || surface.metal()) return nullptr;
  const Window w = (Window)surface.x11Window();
  if (w == 0) return nullptr;
  return std::make_unique<X11Embedder>(surface, w);
}

#else

std::unique_ptr<PlatformViewEmbedder> MakePlatformViewEmbedder(GlfwSurface&) { return nullptr; }

unsigned long GlfwSurface::x11Window() const { return 0ul; }

#endif

}  // namespace rni
