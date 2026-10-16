// FP-50: the paint, path, filter and paragraph half of the draw-op hooks (see DrawOpHook.h).
// A Capture keeps one description per object, keyed by handle, because Impeller's objects are
// opaque: a paint's colour or a path's segments cannot be read back from the handle.
// This file must NOT include DrawOpHook.h: it calls the real names.
#include <cstring>

#include "scenegraph/DrawOpFormat.h"
#include "scenegraph/DrawOpHookDecl.h"

namespace rni::drawop::hook {

namespace {

std::string Described(Capture& c, const void* h) {
  const auto it = c.objects.find(h);
  return it == c.objects.end() ? "?" : it->second;
}

std::string Stops(uint32_t n, const ImpellerColor* colors, const float* stops) {
  std::string s = "stops=[";
  for (uint32_t i = 0; i < n && colors; ++i) {
    s += (i ? " " : "") + Color(&colors[i]) + "@" + (stops ? N(stops[i]) : "-");
  }
  return s + "]";
}

void Segment(Capture& c, ImpellerPathBuilder b, const std::string& cmd) {
  PathState& p = c.pathBuilders[b];
  p.cmds += (p.cmds.empty() ? "" : " ") + cmd;
}

}  // namespace

ImpellerPaint PaintNew() {
  ImpellerPaint p = ImpellerPaintNew();
  if (Capture* c = Current()) c->paints[p] = PaintState{};
  return p;
}

void PaintSetColor(ImpellerPaint p, const ImpellerColor* color) {
  ImpellerPaintSetColor(p, color);
  if (Capture* c = Current()) c->paints[p].color = Color(color);
}
void PaintSetBlendMode(ImpellerPaint p, ImpellerBlendMode mode) {
  ImpellerPaintSetBlendMode(p, mode);
  if (Capture* c = Current()) {
    c->paints[p].blend = mode == kImpellerBlendModeSourceOver ? "" : std::string("blend=") + BlendName((int)mode);
  }
}

namespace {
// Style, width, cap, join and miter ride in one token group so a fill paint stays short.
void Refresh(Capture& c, ImpellerPaint p) {
  PaintState& s = c.paints[p];
  if (s.style == kImpellerDrawStyleFill) {
    s.stroke.clear();
    return;
  }
  s.stroke = std::string(s.style == kImpellerDrawStyleStroke ? "stroke" : "strokefill") + " w=" + N(s.width) +
             " cap=" + std::to_string(s.cap) + " join=" + std::to_string(s.join) + " miter=" + N(s.miter);
}
}  // namespace

void PaintSetDrawStyle(ImpellerPaint p, ImpellerDrawStyle style) {
  ImpellerPaintSetDrawStyle(p, style);
  if (Capture* c = Current()) { c->paints[p].style = (int)style; Refresh(*c, p); }
}
void PaintSetStrokeCap(ImpellerPaint p, ImpellerStrokeCap cap) {
  ImpellerPaintSetStrokeCap(p, cap);
  if (Capture* c = Current()) { c->paints[p].cap = (int)cap; Refresh(*c, p); }
}
void PaintSetStrokeJoin(ImpellerPaint p, ImpellerStrokeJoin join) {
  ImpellerPaintSetStrokeJoin(p, join);
  if (Capture* c = Current()) { c->paints[p].join = (int)join; Refresh(*c, p); }
}
void PaintSetStrokeWidth(ImpellerPaint p, float width) {
  ImpellerPaintSetStrokeWidth(p, width);
  if (Capture* c = Current()) { c->paints[p].width = width; Refresh(*c, p); }
}
void PaintSetStrokeMiter(ImpellerPaint p, float miter) {
  ImpellerPaintSetStrokeMiter(p, miter);
  if (Capture* c = Current()) { c->paints[p].miter = miter; Refresh(*c, p); }
}
void PaintSetColorFilter(ImpellerPaint p, ImpellerColorFilter f) {
  ImpellerPaintSetColorFilter(p, f);
  if (Capture* c = Current()) c->paints[p].colorFilter = "cf=" + Described(*c, f);
}
void PaintSetColorSource(ImpellerPaint p, ImpellerColorSource s) {
  ImpellerPaintSetColorSource(p, s);
  if (Capture* c = Current()) c->paints[p].colorSource = "src=" + Described(*c, s);
}
void PaintSetImageFilter(ImpellerPaint p, ImpellerImageFilter f) {
  ImpellerPaintSetImageFilter(p, f);
  if (Capture* c = Current()) c->paints[p].imageFilter = "imf=" + Described(*c, f);
}
void PaintSetMaskFilter(ImpellerPaint p, ImpellerMaskFilter f) {
  ImpellerPaintSetMaskFilter(p, f);
  if (Capture* c = Current()) c->paints[p].maskFilter = "mf=" + Described(*c, f);
}

ImpellerPathBuilder PathBuilderNew() {
  ImpellerPathBuilder b = ImpellerPathBuilderNew();
  if (Capture* c = Current()) c->pathBuilders[b] = PathState{};
  return b;
}
void PathBuilderMoveTo(ImpellerPathBuilder b, const ImpellerPoint* p) {
  ImpellerPathBuilderMoveTo(b, p);
  if (Capture* c = Current() ; c && p) { Segment(*c, b, "M" + Pt(p)); Grow(c->pathBuilders[b].bounds, p->x, p->y); }
}
void PathBuilderLineTo(ImpellerPathBuilder b, const ImpellerPoint* p) {
  ImpellerPathBuilderLineTo(b, p);
  if (Capture* c = Current() ; c && p) { Segment(*c, b, "L" + Pt(p)); Grow(c->pathBuilders[b].bounds, p->x, p->y); }
}
void PathBuilderQuadraticCurveTo(ImpellerPathBuilder b, const ImpellerPoint* cp, const ImpellerPoint* end) {
  ImpellerPathBuilderQuadraticCurveTo(b, cp, end);
  if (Capture* c = Current() ; c && cp && end) {
    Segment(*c, b, "Q" + Pt(cp) + Pt(end));
    Grow(c->pathBuilders[b].bounds, cp->x, cp->y);
    Grow(c->pathBuilders[b].bounds, end->x, end->y);
  }
}
void PathBuilderCubicCurveTo(ImpellerPathBuilder b, const ImpellerPoint* c1, const ImpellerPoint* c2,
                             const ImpellerPoint* end) {
  ImpellerPathBuilderCubicCurveTo(b, c1, c2, end);
  if (Capture* c = Current() ; c && c1 && c2 && end) {
    Segment(*c, b, "C" + Pt(c1) + Pt(c2) + Pt(end));
    for (const ImpellerPoint* p : {c1, c2, end}) Grow(c->pathBuilders[b].bounds, p->x, p->y);
  }
}
void PathBuilderAddRect(ImpellerPathBuilder b, const ImpellerRect* r) {
  ImpellerPathBuilderAddRect(b, r);
  if (Capture* c = Current() ; c && r) { Segment(*c, b, Rect(r)); GrowRect(c->pathBuilders[b].bounds, *r); }
}
void PathBuilderAddRoundedRect(ImpellerPathBuilder b, const ImpellerRect* r, const ImpellerRoundingRadii* radii) {
  ImpellerPathBuilderAddRoundedRect(b, r, radii);
  if (Capture* c = Current() ; c && r) {
    Segment(*c, b, "rrect" + Rect(r).substr(4) + " " + Radii(radii));
    GrowRect(c->pathBuilders[b].bounds, *r);
  }
}
void PathBuilderClose(ImpellerPathBuilder b) {
  ImpellerPathBuilderClose(b);
  if (Capture* c = Current()) Segment(*c, b, "Z");
}
ImpellerPath PathBuilderTakePathNew(ImpellerPathBuilder b, ImpellerFillType fill) {
  ImpellerPath path = ImpellerPathBuilderTakePathNew(b, fill);
  Capture* c = Current();
  if (c && c->pathBuilders.count(b)) {
    PathState s = c->pathBuilders[b];
    s.cmds += std::string(s.cmds.empty() ? "" : " ") + (fill == kImpellerFillTypeOdd ? "odd" : "nonzero");
    c->paths[path] = s;
    c->pathBuilders[b] = PathState{};  // Impeller resets the builder on take
  }
  return path;
}

ImpellerColorSource ColorSourceCreateLinearGradientNew(const ImpellerPoint* a, const ImpellerPoint* b, uint32_t n,
                                                       const ImpellerColor* colors, const float* stops,
                                                       ImpellerTileMode tile, const ImpellerMatrix* xf) {
  ImpellerColorSource s = ImpellerColorSourceCreateLinearGradientNew(a, b, n, colors, stops, tile, xf);
  if (Capture* c = Current()) {
    c->objects[s] = "linear(" + Pt(a) + "->" + Pt(b) + " " + Stops(n, colors, stops) + " tile=" +
                    std::to_string((int)tile) + (xf ? " xf=" + Matrix(*xf) : "") + ")";
  }
  return s;
}
ImpellerColorSource ColorSourceCreateRadialGradientNew(const ImpellerPoint* center, float radius, uint32_t n,
                                                       const ImpellerColor* colors, const float* stops,
                                                       ImpellerTileMode tile, const ImpellerMatrix* xf) {
  ImpellerColorSource s = ImpellerColorSourceCreateRadialGradientNew(center, radius, n, colors, stops, tile, xf);
  if (Capture* c = Current()) {
    c->objects[s] = "radial(" + Pt(center) + " r=" + N(radius) + " " + Stops(n, colors, stops) + " tile=" +
                    std::to_string((int)tile) + (xf ? " xf=" + Matrix(*xf) : "") + ")";
  }
  return s;
}
ImpellerColorSource ColorSourceCreateImageNew(ImpellerTexture image, ImpellerTileMode h, ImpellerTileMode v,
                                              ImpellerTextureSampling sampling, const ImpellerMatrix* xf) {
  ImpellerColorSource s = ImpellerColorSourceCreateImageNew(image, h, v, sampling, xf);
  if (Capture* c = Current()) {
    c->objects[s] = "image(tile=" + std::to_string((int)h) + "," + std::to_string((int)v) +
                    " sampling=" + std::to_string((int)sampling) + (xf ? " xf=" + Matrix(*xf) : "") + ")";
  }
  return s;
}
ImpellerImageFilter ImageFilterCreateBlurNew(float sx, float sy, ImpellerTileMode tile) {
  ImpellerImageFilter f = ImpellerImageFilterCreateBlurNew(sx, sy, tile);
  if (Capture* c = Current()) c->objects[f] = "blur(" + N(sx) + "," + N(sy) + " tile=" + std::to_string((int)tile) + ")";
  return f;
}
ImpellerColorFilter ColorFilterCreateBlendNew(const ImpellerColor* color, ImpellerBlendMode mode) {
  ImpellerColorFilter f = ImpellerColorFilterCreateBlendNew(color, mode);
  if (Capture* c = Current()) c->objects[f] = "blend(" + Color(color) + "," + BlendName((int)mode) + ")";
  return f;
}
ImpellerColorFilter ColorFilterCreateColorMatrixNew(const ImpellerColorMatrix* m) {
  ImpellerColorFilter f = ImpellerColorFilterCreateColorMatrixNew(m);
  if (Capture* c = Current(); c && m) {
    std::string s = "matrix(";
    for (int i = 0; i < 20; ++i) s += (i ? " " : "") + N(m->m[i]);
    c->objects[f] = s + ")";
  }
  return f;
}
ImpellerMaskFilter MaskFilterCreateBlurNew(ImpellerBlurStyle style, float sigma) {
  ImpellerMaskFilter f = ImpellerMaskFilterCreateBlurNew(style, sigma);
  if (Capture* c = Current()) c->objects[f] = "maskblur(" + std::to_string((int)style) + "," + N(sigma) + ")";
  return f;
}

ImpellerParagraphStyle ParagraphStyleNew() {
  ImpellerParagraphStyle s = ImpellerParagraphStyleNew();
  if (Capture* c = Current()) c->styles[s] = StyleState{};
  return s;
}
void ParagraphStyleSetFontSize(ImpellerParagraphStyle s, float size) {
  ImpellerParagraphStyleSetFontSize(s, size);
  if (Capture* c = Current()) c->styles[s].size = size;
}
void ParagraphStyleSetFontFamily(ImpellerParagraphStyle s, const char* family) {
  ImpellerParagraphStyleSetFontFamily(s, family);
  if (Capture* c = Current()) c->styles[s].family = family ? family : "";
}
ImpellerParagraphBuilder ParagraphBuilderNew(ImpellerTypographyContext ctx) {
  ImpellerParagraphBuilder b = ImpellerParagraphBuilderNew(ctx);
  if (Capture* c = Current()) c->paraBuilders[b] = ParaBuilderState{};
  return b;
}
void ParagraphBuilderPushStyle(ImpellerParagraphBuilder b, ImpellerParagraphStyle style) {
  ImpellerParagraphBuilderPushStyle(b, style);
  if (Capture* c = Current()) {
    const auto it = c->styles.find(style);
    c->paraBuilders[b].cur = it == c->styles.end() ? StyleState{} : it->second;
  }
}
void ParagraphBuilderAddText(ImpellerParagraphBuilder b, const uint8_t* data, uint32_t length) {
  ImpellerParagraphBuilderAddText(b, data, length);
  Capture* c = Current();
  if (!c) return;
  ParaBuilderState& pb = c->paraBuilders[b];
  std::string run = "\"" + std::string(reinterpret_cast<const char*>(data), length) + "\"";
  if (pb.cur.size > 0) run += "@" + N(pb.cur.size);
  if (!pb.cur.family.empty()) run += " " + pb.cur.family;
  pb.runs += (pb.runs.empty() ? "" : " + ") + run;
}
ImpellerParagraph ParagraphBuilderBuildParagraphNew(ImpellerParagraphBuilder b, float width) {
  ImpellerParagraph p = ImpellerParagraphBuilderBuildParagraphNew(b, width);
  if (Capture* c = Current()) c->objects[p] = "text(" + c->paraBuilders[b].runs + " width=" + N(width) + ")";
  return p;
}

}  // namespace rni::drawop::hook
