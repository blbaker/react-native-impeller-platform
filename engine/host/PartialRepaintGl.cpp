// FP-18: see PartialRepaint.h (model: impeller/renderer/backend/metal/
// surface_mtl.mm partial-repaint blit, flow/compositor_context.cc 0.7 rule).
#include "host/PartialRepaint.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#if defined(__linux__) && !defined(__ANDROID__)
#define RNI_PARTIAL_REPAINT_GL 1
#include <GLES3/gl3.h>
#else
#define RNI_PARTIAL_REPAINT_GL 0
#endif

#include "base/Trace.h"

namespace rni {

namespace {
bool EnvOn(const char* name) {
  const char* v = std::getenv(name);
  return v && std::strcmp(v, "1") == 0;
}
}  // namespace

void PartialRepaint::Log(const FrameItem& item, const char* mode, const char* reason,
                         long long px) const {
  if (!log_) return;
  const FrameDamage& d = item.damage;
  std::printf("rn-impeller: damage frame=%llu seq=%llu base=%llu mode=%s x=%d y=%d w=%d h=%d "
              "px=%lld surface_px=%lld reason=%s\n",
              (unsigned long long)item.frameNumber, (unsigned long long)d.seq,
              (unsigned long long)d.baseSeq, mode, d.x, d.y, d.w, d.h, px,
              (long long)item.width * item.height, reason);
}

void PartialRepaint::PrintSummary() const {
  const Stats& s = stats_;
  std::printf("rn-impeller: partial_repaint enabled=%d frames=%llu partial=%llu full=%llu "
              "no_change=%llu base_mismatch=%llu failed=%llu px=%lld surface_px=%lld "
              "repaint_pct=%.3f\n",
              enabled_ ? 1 : 0, (unsigned long long)s.frames, (unsigned long long)s.partial,
              (unsigned long long)s.full, (unsigned long long)s.noChange,
              (unsigned long long)s.baseMismatch, (unsigned long long)s.failed, s.px,
              s.surfacePx, s.surfacePx > 0 ? 100.0 * (double)s.px / (double)s.surfacePx : 0.0);
  if (verify_) {
    std::printf("rn-impeller: partial_verify frames=%llu mismatched_frames=%llu max_px=%lld\n",
                (unsigned long long)s.verified, (unsigned long long)s.verifyMismatchFrames,
                s.verifyMaxPx);
  }
  std::fflush(stdout);
}

#if RNI_PARTIAL_REPAINT_GL

bool PartialRepaint::Init(bool requested) {
  log_ = EnvOn("RNI_DAMAGE_LOG");
  verify_ = EnvOn("RNI_TEST_PARTIAL_VERIFY");
  const char* reason = "ok";
  if (!requested) {
    reason = "off";
  } else {
    // A blit into a multisampled draw framebuffer is GL_INVALID_OPERATION.
    GLint samples = 0;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glGetIntegerv(GL_SAMPLES, &samples);
    if (samples > 0) reason = "msaa_window";
  }
  enabled_ = std::strcmp(reason, "ok") == 0;
  std::printf("rn-impeller: partial_repaint_init requested=%d enabled=%d reason=%s "
              "store=offscreen_root log=%d verify=%d\n",
              requested ? 1 : 0, enabled_ ? 1 : 0, reason, log_ ? 1 : 0, verify_ ? 1 : 0);
  std::fflush(stdout);
  return enabled_;
}

void PartialRepaint::Free(Target& t) {
  if (t.surface) ImpellerSurfaceRelease(t.surface);
  if (t.fbo) glDeleteFramebuffers(1, &t.fbo);
  if (t.tex) glDeleteTextures(1, &t.tex);
  if (t.ds) glDeleteRenderbuffers(1, &t.ds);
  t = Target{};
}

// Storage matches the window when `exact`, else grows; the Impeller wrap is
// the requested size at the bottom-left of the attachment.
bool PartialRepaint::Ensure(ImpellerContext ctx, Target& t, int w, int h, bool exact) {
  const bool fits = exact ? (t.allocW == w && t.allocH == h) : (t.allocW >= w && t.allocH >= h);
  if (!t.fbo || !fits) {
    Free(t);
    const int aw = exact ? w : ((w + 63) / 64) * 64;
    const int ah = exact ? h : ((h + 63) / 64) * 64;
    glGenTextures(1, &t.tex);
    glBindTexture(GL_TEXTURE_2D, t.tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, aw, ah, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glBindTexture(GL_TEXTURE_2D, 0);
    // Impeller's GLES clips and concave fills need a stencil (HeadlessSurface).
    glGenRenderbuffers(1, &t.ds);
    glBindRenderbuffer(GL_RENDERBUFFER, t.ds);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, aw, ah);
    glGenFramebuffers(1, &t.fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, t.fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t.tex, 0);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, t.ds);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, t.ds);
    const bool complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (!complete) {
      Free(t);
      return false;
    }
    t.allocW = aw;
    t.allocH = ah;
  }
  if (!t.surface || t.surfW != w || t.surfH != h) {
    if (t.surface) ImpellerSurfaceRelease(t.surface);
    const ImpellerISize size = {w, h};
    t.surface = ImpellerSurfaceCreateWrappedFBONew(ctx, t.fbo, kImpellerPixelFormatRGBA8888, &size);
    t.surfW = w;
    t.surfH = h;
  }
  return t.surface != nullptr;
}

bool PartialRepaint::DrawInto(ImpellerContext ctx, Target& t, int w, int h,
                              ImpellerDisplayList dl) {
  return dl && Ensure(ctx, t, w, h, /*exact=*/true) &&
         ImpellerSurfaceDrawDisplayList(t.surface, dl);
}

namespace {
// Rows are GL rows (bottom-left origin); Impeller draws the top of the image
// into the top row of its viewport, so device row y lives at GL row h-1-y.
void Blit(unsigned src, int sx0, int sy0, int sx1, int sy1, unsigned dst, int dx0, int dy0,
          int dx1, int dy1) {
  glDisable(GL_SCISSOR_TEST);
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, src);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, dst);
  glBlitFramebuffer(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
}
}  // namespace

bool PartialRepaint::Draw(ImpellerContext ctx, FrameItem& item) {
  const int W = item.width, H = item.height;
  const FrameDamage& d = item.damage;
  ++stats_.frames;
  stats_.surfacePx += (long long)W * H;
  if (!Ensure(ctx, root_, W, H, /*exact=*/true)) {
    ++stats_.failed;
    return false;
  }
  if (root_.surfW != W || root_.surfH != H) rootValid_ = false;
  // Buffer age: R holds exactly walk rootSeq_; a clip is only valid on top of
  // the walk it was diffed against.
  const bool canPartial = d.partial && item.fullList && rootValid_ && rootSeq_ == d.baseSeq;
  bool ok = true;
  if (!canPartial) {
    if (d.partial) ++stats_.baseMismatch;
    TRACE_EVENT0("raster", "DrawFull");
    ok = DrawInto(ctx, root_, W, H, item.fullList ? item.fullList : item.displayList);
    ++stats_.full;
    stats_.px += (long long)W * H;
    Log(item, "full", d.partial ? "base_mismatch" : d.reason, (long long)W * H);
  } else if (d.w <= 0 || d.h <= 0) {
    ++stats_.noChange;
    Log(item, "none", d.reason, 0);
  } else {
    TRACE_EVENT0("raster", "DrawPartial");
    ok = DrawInto(ctx, scratch_, W, H, item.displayList);
    const int y0 = H - d.y - d.h, y1 = H - d.y;  // GL rows of the damage
    if (ok) Blit(scratch_.fbo, d.x, y0, d.x + d.w, y1, root_.fbo, d.x, y0, d.x + d.w, y1);
    ++stats_.partial;
    stats_.px += (long long)d.w * d.h;
    Log(item, "partial", d.reason, (long long)d.w * d.h);
  }
  rootValid_ = ok;
  rootSeq_ = d.seq;
  if (!ok) {
    ++stats_.failed;
    return false;
  }
  if (verify_ && canPartial) {
    const long long bad = Verify(ctx, item, W, H);
    ++stats_.verified;
    if (bad > 0) {
      ++stats_.verifyMismatchFrames;
      if (bad > stats_.verifyMaxPx) stats_.verifyMaxPx = bad;
      std::printf("rn-impeller: partial_verify_mismatch frame=%llu px=%lld\n",
                  (unsigned long long)item.frameNumber, bad);
    }
  }
  {
    TRACE_EVENT0("raster", "BlitRoot");
    Blit(root_.fbo, 0, 0, W, H, 0, 0, 0, W, H);
  }
  glFinish();  // as GlfwSurface::drawDisplayList: raster_end is GPU-complete
  return true;
}

// RNI_TEST_PARTIAL_VERIFY: the same frame repainted in full must equal R.
long long PartialRepaint::Verify(ImpellerContext ctx, FrameItem& item, int w, int h) {
  if (!DrawInto(ctx, check_, w, h, item.fullList)) return (long long)w * h;
  std::vector<uint32_t> a((size_t)w * h), b((size_t)w * h);
  glBindFramebuffer(GL_FRAMEBUFFER, root_.fbo);
  glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, a.data());
  glBindFramebuffer(GL_FRAMEBUFFER, check_.fbo);
  glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, b.data());
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  long long bad = 0;
  size_t first = 0;
  for (size_t i = 0; i < a.size(); ++i) {
    if (a[i] != b[i] && bad++ == 0) first = i;
  }
  if (bad > 0) {
    std::printf("rn-impeller: partial_verify_first frame=%llu x=%d y=%d partial=%08x full=%08x\n",
                (unsigned long long)item.frameNumber, (int)(first % (size_t)w),
                h - 1 - (int)(first / (size_t)w), a[first], b[first]);
  }
  return bad;
}

void PartialRepaint::Release() {
  Free(root_);
  Free(scratch_);
  Free(check_);
  rootValid_ = false;
}

#else  // !RNI_PARTIAL_REPAINT_GL

bool PartialRepaint::Init(bool requested) {
  enabled_ = false;
  std::printf("rn-impeller: partial_repaint_init requested=%d enabled=0 "
              "reason=unsupported_platform store=none log=0 verify=0\n",
              requested ? 1 : 0);
  std::fflush(stdout);
  return false;
}
bool PartialRepaint::Draw(ImpellerContext, FrameItem&) { return false; }
void PartialRepaint::Release() {}

#endif

}  // namespace rni
