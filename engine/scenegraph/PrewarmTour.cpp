#include "scenegraph/PrewarmTour.h"

#include <string>

namespace rni {

namespace {

// Everything is drawn over this box. It must cover the 1x1 target's pixel: Impeller culls a draw
// that does not touch the target, and a culled draw compiles nothing.
const ImpellerRect kBox = {-2.0f, -2.0f, 8.0f, 8.0f};

struct Tour {
  ImpellerDisplayListBuilder b;
  PrewarmCounts* c;

  void Fill(const ImpellerColor& color, ImpellerPaint paint = nullptr) {
    ImpellerPaint p = paint ? paint : ImpellerPaintNew();
    ImpellerPaintSetColor(p, &color);
    ImpellerDisplayListBuilderDrawRect(b, &kBox, p);
    ++c->draws;
    if (!paint) ImpellerPaintRelease(p);
  }
  static ImpellerColor Rgba(float r, float g, float bl, float a) {
    return {r, g, bl, a, kImpellerColorSpaceSRGB};
  }
};

// The modes ToImpellerBlend (BlendGroup.cpp) can return; the painter only blends through a layer.
const ImpellerBlendMode kBlendModes[] = {
    kImpellerBlendModeSourceOver, kImpellerBlendModeMultiply,   kImpellerBlendModeScreen,
    kImpellerBlendModeOverlay,    kImpellerBlendModeDarken,     kImpellerBlendModeLighten,
    kImpellerBlendModeColorDodge, kImpellerBlendModeColorBurn,  kImpellerBlendModeHardLight,
    kImpellerBlendModeSoftLight,  kImpellerBlendModeDifference, kImpellerBlendModeExclusion,
    kImpellerBlendModeHue,        kImpellerBlendModeSaturation, kImpellerBlendModeColor,
    kImpellerBlendModeLuminosity, kImpellerBlendModePlus,
};

void BlendModes(Tour& t) {
  const ImpellerColor dst = Tour::Rgba(0.2f, 0.5f, 0.8f, 1.0f);
  const ImpellerColor src = Tour::Rgba(0.9f, 0.4f, 0.1f, 0.8f);
  for (ImpellerBlendMode mode : kBlendModes) {
    // BeginBlendGroup: the layer composites onto what is below with the mode.
    t.Fill(dst);
    ImpellerPaint lp = ImpellerPaintNew();
    ImpellerPaintSetBlendMode(lp, mode);
    ImpellerDisplayListBuilderSaveLayer(t.b, &kBox, lp, nullptr);
    ImpellerPaintRelease(lp);
    t.Fill(src);
    ImpellerDisplayListBuilderRestore(t.b);
    ++t.c->blendModes;
    ++t.c->layers;
  }
}

ImpellerPath ConcavePath(bool star) {
  ImpellerPathBuilder pb = ImpellerPathBuilderNew();
  const float pts[][2] = {{0, 0}, {60, 4}, {20, 20}, {58, 58}, {0, 40}};
  ImpellerPoint p0 = {pts[0][0] - 2, pts[0][1] - 2};
  ImpellerPathBuilderMoveTo(pb, &p0);
  const int n = star ? 5 : 4;
  for (int i = 1; i < n; ++i) {
    ImpellerPoint p = {pts[i][0] - 2, pts[i][1] - 2};
    ImpellerPathBuilderLineTo(pb, &p);
  }
  ImpellerPathBuilderClose(pb);
  ImpellerPath path = ImpellerPathBuilderTakePathNew(pb, kImpellerFillTypeNonZero);
  ImpellerPathBuilderRelease(pb);
  return path;
}

void Clips(Tour& t) {
  const ImpellerColor fill = Tour::Rgba(0.3f, 0.7f, 0.4f, 1.0f);
  const ImpellerRoundingRadii rr = {{8, 8}, {8, 8}, {8, 8}, {8, 8}};
  const ImpellerRoundingRadii ell = {{20, 12}, {20, 12}, {20, 12}, {20, 12}};
  auto clipped = [&](auto&& clip) {
    ImpellerDisplayListBuilderSave(t.b);
    clip();
    t.Fill(fill);
    ImpellerDisplayListBuilderRestore(t.b);
    ++t.c->clips;
  };
  clipped([&] { ImpellerDisplayListBuilderClipRect(t.b, &kBox, kImpellerClipOperationIntersect); });
  clipped([&] { ImpellerDisplayListBuilderClipRect(t.b, &kBox, kImpellerClipOperationDifference); });
  clipped([&] {
    ImpellerDisplayListBuilderClipRoundedRect(t.b, &kBox, &rr, kImpellerClipOperationIntersect);
  });
  clipped([&] {
    ImpellerDisplayListBuilderClipRoundedRect(t.b, &kBox, &ell, kImpellerClipOperationIntersect);
  });
  clipped([&] { ImpellerDisplayListBuilderClipOval(t.b, &kBox, kImpellerClipOperationIntersect); });
  for (bool star : {false, true}) {
    ImpellerPath path = ConcavePath(star);
    clipped([&] { ImpellerDisplayListBuilderClipPath(t.b, path, kImpellerClipOperationIntersect); });
    ImpellerPaint p = ImpellerPaintNew();
    t.Fill(fill, p);  // stencil-then-cover needs a path fill too
    ImpellerDisplayListBuilderDrawPath(t.b, path, p);
    ++t.c->draws;
    ImpellerPaintSetDrawStyle(p, kImpellerDrawStyleStroke);
    ImpellerPaintSetStrokeWidth(p, 3.0f);
    ImpellerPaintSetStrokeCap(p, kImpellerStrokeCapRound);
    ImpellerPaintSetStrokeJoin(p, kImpellerStrokeJoinRound);
    ImpellerDisplayListBuilderDrawPath(t.b, path, p);
    ++t.c->draws;
    ImpellerPaintRelease(p);
    ImpellerPathRelease(path);
  }
  ImpellerPaint sp = ImpellerPaintNew();
  ImpellerPaintSetColor(sp, &fill);
  ImpellerPaintSetDrawStyle(sp, kImpellerDrawStyleStroke);
  ImpellerPaintSetStrokeWidth(sp, 2.0f);
  ImpellerDisplayListBuilderDrawRoundedRect(t.b, &kBox, &rr, sp);
  ImpellerDisplayListBuilderDrawOval(t.b, &kBox, sp);
  ImpellerPaintSetDrawStyle(sp, kImpellerDrawStyleFill);
  ImpellerDisplayListBuilderDrawRoundedRect(t.b, &kBox, &rr, sp);
  ImpellerDisplayListBuilderDrawOval(t.b, &kBox, sp);
  const ImpellerRect inner = {4, 4, 40, 40};
  ImpellerDisplayListBuilderDrawRoundedRectDifference(t.b, &kBox, &rr, &inner, &rr, sp);
  t.c->draws += 5;
  ImpellerPaintRelease(sp);
  ++t.c->clips;
}

void Layers(Tour& t) {
  ImpellerPaint op = ImpellerPaintNew();  // opacity
  const ImpellerColor half = Tour::Rgba(1, 1, 1, 0.5f);
  ImpellerPaintSetColor(op, &half);
  ImpellerDisplayListBuilderSaveLayer(t.b, &kBox, op, nullptr);
  t.Fill(Tour::Rgba(0.8f, 0.2f, 0.2f, 1));
  ImpellerDisplayListBuilderRestore(t.b);
  ImpellerPaintRelease(op);
  ++t.c->layers;

  ImpellerPaint mp = ImpellerPaintNew();  // color matrix (filter: grayscale, sepia, ...)
  ImpellerColorMatrix cm = {{0.33f, 0.33f, 0.33f, 0, 0, 0.33f, 0.33f, 0.33f, 0, 0,
                             0.33f, 0.33f, 0.33f, 0, 0, 0, 0, 0, 1, 0}};
  ImpellerColorFilter mf = ImpellerColorFilterCreateColorMatrixNew(&cm);
  ImpellerPaintSetColorFilter(mp, mf);
  ImpellerColorFilterRelease(mf);
  ImpellerDisplayListBuilderSaveLayer(t.b, &kBox, mp, nullptr);
  t.Fill(Tour::Rgba(0.8f, 0.2f, 0.2f, 1));
  ImpellerDisplayListBuilderRestore(t.b);
  ImpellerPaintRelease(mp);
  ++t.c->layers;

  ImpellerPaint tp = ImpellerPaintNew();  // tintColor: SourceIn blend color filter
  const ImpellerColor tint = Tour::Rgba(0.1f, 0.6f, 0.9f, 1);
  ImpellerColorFilter tf = ImpellerColorFilterCreateBlendNew(&tint, kImpellerBlendModeSourceIn);
  ImpellerPaintSetColorFilter(tp, tf);
  ImpellerColorFilterRelease(tf);
  ImpellerDisplayListBuilderSaveLayer(t.b, &kBox, tp, nullptr);
  t.Fill(Tour::Rgba(0.8f, 0.2f, 0.2f, 1));
  ImpellerDisplayListBuilderRestore(t.b);
  ImpellerPaintRelease(tp);
  ++t.c->layers;
}

void Blurs(Tour& t) {
  for (float sigma : {2.0f, 9.0f}) {  // content blur (filter: blur), decal; two kernel sizes
    ImpellerPaint p = ImpellerPaintNew();
    ImpellerImageFilter f = ImpellerImageFilterCreateBlurNew(sigma, sigma, kImpellerTileModeDecal);
    ImpellerPaintSetImageFilter(p, f);
    ImpellerImageFilterRelease(f);
    ImpellerDisplayListBuilderSaveLayer(t.b, &kBox, p, nullptr);
    t.Fill(Tour::Rgba(0.9f, 0.9f, 0.2f, 1));
    ImpellerDisplayListBuilderRestore(t.b);
    ImpellerPaintRelease(p);
    ++t.c->blurs;
    ++t.c->layers;
  }
  for (float sigma : {3.0f, 14.0f}) {  // expo-blur backdrop, clamp
    ImpellerImageFilter f = ImpellerImageFilterCreateBlurNew(sigma, sigma, kImpellerTileModeClamp);
    ImpellerDisplayListBuilderSaveLayer(t.b, &kBox, nullptr, f);
    ImpellerImageFilterRelease(f);
    t.Fill(Tour::Rgba(1, 1, 1, 0.3f));
    ImpellerDisplayListBuilderRestore(t.b);
    ++t.c->blurs;
    ++t.c->layers;
  }
  const ImpellerBlurStyle styles[] = {kImpellerBlurStyleNormal, kImpellerBlurStyleSolid,
                                      kImpellerBlurStyleOuter, kImpellerBlurStyleInner};
  for (ImpellerBlurStyle style : styles) {  // box-shadow / text-shadow mask blur
    ImpellerPaint p = ImpellerPaintNew();
    ImpellerMaskFilter m = ImpellerMaskFilterCreateBlurNew(style, 4.0f);
    ImpellerPaintSetMaskFilter(p, m);
    ImpellerMaskFilterRelease(m);
    const ImpellerRoundingRadii rr = {{6, 6}, {6, 6}, {6, 6}, {6, 6}};
    const ImpellerColor c = Tour::Rgba(0, 0, 0, 0.4f);
    ImpellerPaintSetColor(p, &c);
    ImpellerDisplayListBuilderDrawRoundedRect(t.b, &kBox, &rr, p);
    ++t.c->draws;
    ImpellerPaintRelease(p);
    ++t.c->blurs;
  }
  ImpellerPath path = ConcavePath(false);  // elevation shadow
  const ImpellerColor sc = Tour::Rgba(0, 0, 0, 1);
  ImpellerDisplayListBuilderDrawShadow(t.b, path, &sc, 4.0f, false, 1.0f);
  ImpellerPathRelease(path);
  ++t.c->draws;
  ++t.c->blurs;
}

void Gradients(Tour& t) {
  const ImpellerColor colors[3] = {Tour::Rgba(1, 0, 0, 1), Tour::Rgba(0, 1, 0, 1),
                                   Tour::Rgba(0, 0, 1, 0.5f)};
  const float stops2[2] = {0.0f, 1.0f};
  const float stops3[3] = {0.0f, 0.5f, 1.0f};
  const ImpellerPoint a = {-2, -2}, z = {60, 60};
  for (int stopCount : {2, 3}) {  // SceneGraph::makeGradientSource: linear and radial, clamp
    const float* stops = stopCount == 2 ? stops2 : stops3;
    ImpellerColorSource srcs[2] = {
        ImpellerColorSourceCreateLinearGradientNew(&a, &z, stopCount, colors, stops,
                                                   kImpellerTileModeClamp, nullptr),
        ImpellerColorSourceCreateRadialGradientNew(&a, 40.0f, stopCount, colors, stops,
                                                   kImpellerTileModeClamp, nullptr)};
    for (ImpellerColorSource s : srcs) {
      if (!s) continue;
      ImpellerPaint p = ImpellerPaintNew();
      ImpellerPaintSetColorSource(p, s);
      ImpellerDisplayListBuilderDrawRect(t.b, &kBox, p);
      ++t.c->draws;
      ImpellerPaintRelease(p);
      ImpellerColorSourceRelease(s);
      ++t.c->gradients;
    }
  }
}

void Textures(Tour& t, ImpellerTexture tex) {
  if (!tex) return;
  const ImpellerRect src = {0, 0, 1, 1};
  const ImpellerTextureSampling modes[] = {kImpellerTextureSamplingLinear,
                                        kImpellerTextureSamplingNearestNeighbor};
  for (ImpellerTextureSampling mode : modes) {
    ImpellerPaint p = ImpellerPaintNew();
    ImpellerDisplayListBuilderDrawTextureRect(t.b, tex, &src, &kBox, mode, p);
    ++t.c->draws;
    ++t.c->textures;
    ImpellerPaintRelease(p);
  }
  // Tinted image (tintColor) and a repeating image shader (resizeMode: repeat).
  ImpellerPaint tp = ImpellerPaintNew();
  const ImpellerColor tint = Tour::Rgba(0.9f, 0.1f, 0.1f, 1);
  ImpellerColorFilter tf = ImpellerColorFilterCreateBlendNew(&tint, kImpellerBlendModeSourceIn);
  ImpellerPaintSetColorFilter(tp, tf);
  ImpellerColorFilterRelease(tf);
  ImpellerDisplayListBuilderDrawTextureRect(t.b, tex, &src, &kBox, kImpellerTextureSamplingLinear,
                                            tp);
  ImpellerPaintRelease(tp);
  ++t.c->draws;
  ++t.c->textures;
  const ImpellerMatrix id = {{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}};
  ImpellerColorSource cs = ImpellerColorSourceCreateImageNew(
      tex, kImpellerTileModeRepeat, kImpellerTileModeRepeat, kImpellerTextureSamplingLinear, &id);
  if (cs) {
    ImpellerPaint p = ImpellerPaintNew();
    ImpellerPaintSetColorSource(p, cs);
    ImpellerDisplayListBuilderDrawRect(t.b, &kBox, p);
    ++t.c->draws;
    ++t.c->gradients;
    ImpellerPaintRelease(p);
    ImpellerColorSourceRelease(cs);
  }
}

struct TextClass {
  ImpellerFontWeight weight;
  ImpellerFontStyle style;
  int decoration;
  bool background;
  bool clamp;
};

void Text(Tour& t, ImpellerTypographyContext typography) {
  const TextClass classes[] = {
      {kImpellerFontWeight400, kImpellerFontStyleNormal, 0, false, false},
      {kImpellerFontWeight700, kImpellerFontStyleNormal, 0, false, false},
      {kImpellerFontWeight400, kImpellerFontStyleItalic, 0, false, false},
      {kImpellerFontWeight400, kImpellerFontStyleNormal, kImpellerTextDecorationTypeUnderline, false,
       false},
      {kImpellerFontWeight400, kImpellerFontStyleNormal, kImpellerTextDecorationTypeLineThrough,
       false, false},
      {kImpellerFontWeight400, kImpellerFontStyleNormal, 0, true, false},
      {kImpellerFontWeight400, kImpellerFontStyleNormal, 0, false, true},
  };
  const std::string text = "Hamburgefonstiv 0123 \xE2\x80\xA6";
  for (const TextClass& k : classes) {
    ImpellerParagraphStyle style = ImpellerParagraphStyleNew();
    ImpellerParagraphStyleSetFontSize(style, 28.0f);
    ImpellerParagraphStyleSetFontWeight(style, k.weight);
    ImpellerParagraphStyleSetFontStyle(style, k.style);
    ImpellerPaint fg = ImpellerPaintNew();
    const ImpellerColor c = Tour::Rgba(0.1f, 0.1f, 0.1f, 1);
    ImpellerPaintSetColor(fg, &c);
    ImpellerParagraphStyleSetForeground(style, fg);
    ImpellerPaint bg = nullptr;
    if (k.background) {
      bg = ImpellerPaintNew();
      const ImpellerColor bc = Tour::Rgba(1, 1, 0, 1);
      ImpellerPaintSetColor(bg, &bc);
      ImpellerParagraphStyleSetBackground(style, bg);
    }
    if (k.decoration != 0) {
      ImpellerTextDecoration d = {k.decoration, c, kImpellerTextDecorationStyleSolid, 1.0f};
      ImpellerParagraphStyleSetTextDecoration(style, &d);
    }
    if (k.clamp) {
      ImpellerParagraphStyleSetMaxLines(style, 1);
      ImpellerParagraphStyleSetEllipsis(style, "\xE2\x80\xA6");
    }
    ImpellerParagraphBuilder pb = ImpellerParagraphBuilderNew(typography);
    if (pb) {
      ImpellerParagraphBuilderPushStyle(pb, style);
      ImpellerParagraphBuilderAddText(pb, (const uint8_t*)text.c_str(), (uint32_t)text.size());
      ImpellerParagraphBuilderPopStyle(pb);
      ImpellerParagraph para = ImpellerParagraphBuilderBuildParagraphNew(pb, k.clamp ? 40.0f : 200.0f);
      if (para) {
        const ImpellerPoint at = {-2, -4};
        ImpellerDisplayListBuilderDrawParagraph(t.b, para, &at);
        ++t.c->draws;
        ++t.c->textStyles;
        ImpellerParagraphRelease(para);
      }
      ImpellerParagraphBuilderRelease(pb);
    }
    ImpellerParagraphStyleRelease(style);
    ImpellerPaintRelease(fg);
    if (bg) ImpellerPaintRelease(bg);
  }
}

}  // namespace

ImpellerTexture MakePrewarmTexture(ImpellerContext context) {
  static const uint8_t kPixel[4] = {200, 120, 60, 255};
  ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888, {1, 1}, 1};
  ImpellerMapping mapping = {kPixel, sizeof(kPixel), nullptr};
  return ImpellerTextureCreateWithContentsNew(context, &desc, &mapping, nullptr);
}

ImpellerDisplayList BuildPrewarmTour(ImpellerTypographyContext typography, ImpellerTexture texture,
                                     PrewarmCounts* counts) {
  PrewarmCounts local;
  PrewarmCounts* c = counts ? counts : &local;
  *c = PrewarmCounts{};
  ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
  if (!b) return nullptr;
  Tour t{b, c};
  BlendModes(t);
  Clips(t);
  Layers(t);
  Blurs(t);
  Gradients(t);
  Textures(t, texture);
  Text(t, typography);
  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);
  ImpellerDisplayListBuilderRelease(b);
  return dl;
}

}  // namespace rni
