// FP-50: the builder half of the draw-op hooks (see DrawOpHook.h). Every wrapper calls the real
// Impeller function first, then logs. The transform in the log is read back from the builder
// (ImpellerDisplayListBuilderGetTransform), so it is what Impeller holds, not what we meant to set.
// This file must NOT include DrawOpHook.h: it calls the real names.
#include <algorithm>

#include "scenegraph/DrawOpFormat.h"
#include "scenegraph/DrawOpHookDecl.h"

namespace rni::drawop::hook {

namespace {

BuilderState& Builder(Capture& c, ImpellerDisplayListBuilder b) {
  auto it = c.builders.find(b);
  if (it == c.builders.end()) {
    it = c.builders.emplace(b, BuilderState{}).first;
    it->second.id = c.nextBuilder++;
  }
  return it->second;
}

std::string Paint(Capture& c, ImpellerPaint p) {
  const auto it = c.paints.find(p);
  return it == c.paints.end() ? "paint(?)" : it->second.Str();
}

std::string PathText(Capture& c, ImpellerPath p) {
  if (!p) return "path(null)";
  const auto it = c.paths.find(p);
  if (it != c.paths.end()) return "path[" + it->second.cmds + "]";
  ImpellerRect r{};  // a path built in a translation unit that is not hooked (svg)
  ImpellerPathGetBounds(p, &r);
  return "path(bounds=" + Rect(&r) + ")";
}

Box PathBox(Capture& c, ImpellerPath p) {
  const auto it = c.paths.find(p);
  if (it != c.paths.end()) return it->second.bounds;
  ImpellerRect r{};
  ImpellerPathGetBounds(p, &r);
  Box b;
  GrowRect(b, r);
  return b;
}

std::string Ctm(ImpellerDisplayListBuilder b) {
  ImpellerMatrix m{};
  ImpellerDisplayListBuilderGetTransform(b, &m);
  return Matrix(m);
}

void Add(Capture& c, ImpellerDisplayListBuilder b, std::string text, bool withState) {
  BuilderState& s = Builder(c, b);
  Op op;
  op.builder = s.id;
  op.depth = s.depth;
  op.text = std::move(text);
  if (withState) op.state = "ctm=" + Ctm(b) + " clip=" + BoxStr(s.clips.back());
  c.ops.push_back(std::move(op));
}

// Device-space bounds of `local` under the builder's current transform.
Box Device(ImpellerDisplayListBuilder b, const Box& local) {
  ImpellerMatrix m{};
  ImpellerDisplayListBuilderGetTransform(b, &m);
  Box out;
  if (!local.bounded) return out;
  const float xs[2] = {local.l, local.r}, ys[2] = {local.t, local.b};
  for (float x : xs) {
    for (float y : ys) Grow(out, m.m[0] * x + m.m[4] * y + m.m[12], m.m[1] * x + m.m[5] * y + m.m[13]);
  }
  return out;
}

void Clip(Capture& c, ImpellerDisplayListBuilder b, const char* what, const Box& local,
          ImpellerClipOperation op, const std::string& shape) {
  BuilderState& s = Builder(c, b);
  Box& cur = s.clips.back();
  if (op == kImpellerClipOperationIntersect) {
    const Box dev = Device(b, local);
    if (!cur.bounded) {
      cur = dev;
    } else if (dev.bounded) {
      cur.l = std::fmax(cur.l, dev.l);
      cur.t = std::fmax(cur.t, dev.t);
      cur.r = std::fmin(cur.r, dev.r);
      cur.b = std::fmin(cur.b, dev.b);
    }
  }
  Add(c, b, std::string(what) + " " + shape + (op == kImpellerClipOperationDifference ? " diff" : ""), true);
}

Box RectBox(const ImpellerRect* r) {
  Box b;
  if (r) GrowRect(b, *r);
  return b;
}

}  // namespace

ImpellerDisplayListBuilder DisplayListBuilderNew(const ImpellerRect* cull_rect) {
  ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(cull_rect);
  if (Capture* c = Current()) {
    c->builders.erase(b);
    Builder(*c, b);
  }
  return b;
}

void DisplayListBuilderRelease(ImpellerDisplayListBuilder b) {
  if (Capture* c = Current()) c->builders.erase(b);
  ImpellerDisplayListBuilderRelease(b);
}

void DisplayListBuilderSave(ImpellerDisplayListBuilder b) {
  ImpellerDisplayListBuilderSave(b);
  Capture* c = Current();
  if (!c) return;
  Add(*c, b, "Save", false);
  BuilderState& s = Builder(*c, b);
  s.clips.push_back(s.clips.back());
  ++s.depth;
}

void DisplayListBuilderSaveLayer(ImpellerDisplayListBuilder b, const ImpellerRect* bounds,
                                 ImpellerPaint paint, ImpellerImageFilter backdrop) {
  ImpellerDisplayListBuilderSaveLayer(b, bounds, paint, backdrop);
  Capture* c = Current();
  if (!c) return;
  std::string text = "SaveLayer " + (bounds ? Rect(bounds) : std::string("unbounded"));
  if (paint) text += " " + Paint(*c, paint);
  if (backdrop) {
    const auto it = c->objects.find(backdrop);
    text += " backdrop=" + (it == c->objects.end() ? std::string("?") : it->second);
  }
  Add(*c, b, text, true);
  BuilderState& s = Builder(*c, b);
  s.clips.push_back(s.clips.back());
  ++s.depth;
}

void DisplayListBuilderRestore(ImpellerDisplayListBuilder b) {
  ImpellerDisplayListBuilderRestore(b);
  Capture* c = Current();
  if (!c) return;
  BuilderState& s = Builder(*c, b);
  s.depth = std::max(0, s.depth - 1);
  if (s.clips.size() > 1) s.clips.pop_back();
  Add(*c, b, "Restore", false);
}

void DisplayListBuilderScale(ImpellerDisplayListBuilder b, float x, float y) {
  ImpellerDisplayListBuilderScale(b, x, y);
  if (Capture* c = Current()) Add(*c, b, "Scale " + N(x) + "," + N(y), false);
}
void DisplayListBuilderRotate(ImpellerDisplayListBuilder b, float deg) {
  ImpellerDisplayListBuilderRotate(b, deg);
  if (Capture* c = Current()) Add(*c, b, "Rotate " + N(deg), false);
}
void DisplayListBuilderTranslate(ImpellerDisplayListBuilder b, float x, float y) {
  ImpellerDisplayListBuilderTranslate(b, x, y);
  if (Capture* c = Current()) Add(*c, b, "Translate " + N(x) + "," + N(y), false);
}
void DisplayListBuilderTransform(ImpellerDisplayListBuilder b, const ImpellerMatrix* m) {
  ImpellerDisplayListBuilderTransform(b, m);
  if (Capture* c = Current()) Add(*c, b, "Transform " + (m ? Matrix(*m) : std::string("null")), false);
}

void DisplayListBuilderClipRect(ImpellerDisplayListBuilder b, const ImpellerRect* r, ImpellerClipOperation op) {
  ImpellerDisplayListBuilderClipRect(b, r, op);
  if (Capture* c = Current()) Clip(*c, b, "ClipRect", RectBox(r), op, Rect(r));
}
void DisplayListBuilderClipOval(ImpellerDisplayListBuilder b, const ImpellerRect* r, ImpellerClipOperation op) {
  ImpellerDisplayListBuilderClipOval(b, r, op);
  if (Capture* c = Current()) Clip(*c, b, "ClipOval", RectBox(r), op, Rect(r));
}
void DisplayListBuilderClipRoundedRect(ImpellerDisplayListBuilder b, const ImpellerRect* r,
                                       const ImpellerRoundingRadii* radii, ImpellerClipOperation op) {
  ImpellerDisplayListBuilderClipRoundedRect(b, r, radii, op);
  if (Capture* c = Current()) Clip(*c, b, "ClipRRect", RectBox(r), op, Rect(r) + " " + Radii(radii));
}
void DisplayListBuilderClipPath(ImpellerDisplayListBuilder b, ImpellerPath path, ImpellerClipOperation op) {
  ImpellerDisplayListBuilderClipPath(b, path, op);
  if (Capture* c = Current()) Clip(*c, b, "ClipPath", PathBox(*c, path), op, PathText(*c, path));
}

void DisplayListBuilderDrawPaint(ImpellerDisplayListBuilder b, ImpellerPaint paint) {
  ImpellerDisplayListBuilderDrawPaint(b, paint);
  if (Capture* c = Current()) Add(*c, b, "DrawPaint " + Paint(*c, paint), true);
}
void DisplayListBuilderDrawRect(ImpellerDisplayListBuilder b, const ImpellerRect* r, ImpellerPaint paint) {
  ImpellerDisplayListBuilderDrawRect(b, r, paint);
  if (Capture* c = Current()) Add(*c, b, "DrawRect " + Rect(r) + " " + Paint(*c, paint), true);
}
void DisplayListBuilderDrawOval(ImpellerDisplayListBuilder b, const ImpellerRect* r, ImpellerPaint paint) {
  ImpellerDisplayListBuilderDrawOval(b, r, paint);
  if (Capture* c = Current()) Add(*c, b, "DrawOval " + Rect(r) + " " + Paint(*c, paint), true);
}
void DisplayListBuilderDrawRoundedRect(ImpellerDisplayListBuilder b, const ImpellerRect* r,
                                       const ImpellerRoundingRadii* radii, ImpellerPaint paint) {
  ImpellerDisplayListBuilderDrawRoundedRect(b, r, radii, paint);
  if (Capture* c = Current()) {
    Add(*c, b, "DrawRRect " + Rect(r) + " " + Radii(radii) + " " + Paint(*c, paint), true);
  }
}
void DisplayListBuilderDrawRoundedRectDifference(ImpellerDisplayListBuilder b, const ImpellerRect* outer,
                                                 const ImpellerRoundingRadii* outerRadii,
                                                 const ImpellerRect* inner,
                                                 const ImpellerRoundingRadii* innerRadii, ImpellerPaint paint) {
  ImpellerDisplayListBuilderDrawRoundedRectDifference(b, outer, outerRadii, inner, innerRadii, paint);
  if (Capture* c = Current()) {
    Add(*c, b,
        "DrawDRRect outer=" + Rect(outer) + " " + Radii(outerRadii) + " inner=" + Rect(inner) + " " +
            Radii(innerRadii) + " " + Paint(*c, paint),
        true);
  }
}
void DisplayListBuilderDrawPath(ImpellerDisplayListBuilder b, ImpellerPath path, ImpellerPaint paint) {
  ImpellerDisplayListBuilderDrawPath(b, path, paint);
  if (Capture* c = Current()) Add(*c, b, "DrawPath " + PathText(*c, path) + " " + Paint(*c, paint), true);
}
void DisplayListBuilderDrawShadow(ImpellerDisplayListBuilder b, ImpellerPath path, const ImpellerColor* color,
                                  float elevation, bool transparent, float dpr) {
  ImpellerDisplayListBuilderDrawShadow(b, path, color, elevation, transparent, dpr);
  if (Capture* c = Current()) {
    Add(*c, b,
        "DrawShadow " + PathText(*c, path) + " " + Color(color) + " elev=" + N(elevation) +
            (transparent ? " transparent" : "") + " dpr=" + N(dpr),
        true);
  }
}
void DisplayListBuilderDrawTextureRect(ImpellerDisplayListBuilder b, ImpellerTexture tex, const ImpellerRect* src,
                                       const ImpellerRect* dst, ImpellerTextureSampling sampling,
                                       ImpellerPaint paint) {
  ImpellerDisplayListBuilderDrawTextureRect(b, tex, src, dst, sampling, paint);
  if (Capture* c = Current()) {
    Add(*c, b,
        "DrawTexture src=" + Rect(src) + " dst=" + Rect(dst) + " sampling=" + std::to_string((int)sampling) +
            (paint ? " " + Paint(*c, paint) : ""),
        true);
  }
}
void DisplayListBuilderDrawParagraph(ImpellerDisplayListBuilder b, ImpellerParagraph para, const ImpellerPoint* at) {
  ImpellerDisplayListBuilderDrawParagraph(b, para, at);
  if (Capture* c = Current()) {
    const auto it = c->objects.find(para);
    Add(*c, b, "DrawParagraph at=" + Pt(at) + " " + (it == c->objects.end() ? "text(?)" : it->second), true);
  }
}
void DisplayListBuilderDrawDisplayList(ImpellerDisplayListBuilder b, ImpellerDisplayList dl, float opacity) {
  ImpellerDisplayListBuilderDrawDisplayList(b, dl, opacity);
  if (Capture* c = Current()) Add(*c, b, "DrawDisplayList opacity=" + N(opacity), true);
}

}  // namespace rni::drawop::hook
