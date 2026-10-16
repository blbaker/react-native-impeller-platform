#pragma once
// FP-50: the forwarding wrappers DrawOpHook.h redirects to (defined in DrawOpHooks*.cpp).
#include "impeller.h"

namespace rni::drawop::hook {
  void DisplayListBuilderRelease(ImpellerDisplayListBuilder builder);
  void DisplayListBuilderSave(ImpellerDisplayListBuilder builder);
  void DisplayListBuilderSaveLayer(ImpellerDisplayListBuilder builder, const ImpellerRect* bounds, ImpellerPaint paint, ImpellerImageFilter backdrop);
  void DisplayListBuilderRestore(ImpellerDisplayListBuilder builder);
  void DisplayListBuilderScale(ImpellerDisplayListBuilder builder, float x_scale, float y_scale);
  void DisplayListBuilderRotate(ImpellerDisplayListBuilder builder, float angle_degrees);
  void DisplayListBuilderTranslate(ImpellerDisplayListBuilder builder, float x_translation, float y_translation);
  void DisplayListBuilderTransform(ImpellerDisplayListBuilder builder, const ImpellerMatrix* transform);
  void DisplayListBuilderClipRect(ImpellerDisplayListBuilder builder, const ImpellerRect* rect, ImpellerClipOperation op);
  void DisplayListBuilderClipOval(ImpellerDisplayListBuilder builder, const ImpellerRect* oval_bounds, ImpellerClipOperation op);
  void DisplayListBuilderClipRoundedRect(ImpellerDisplayListBuilder builder, const ImpellerRect* rect, const ImpellerRoundingRadii* radii, ImpellerClipOperation op);
  void DisplayListBuilderClipPath(ImpellerDisplayListBuilder builder, ImpellerPath path, ImpellerClipOperation op);
  void DisplayListBuilderDrawPaint(ImpellerDisplayListBuilder builder, ImpellerPaint paint);
  void DisplayListBuilderDrawRect(ImpellerDisplayListBuilder builder, const ImpellerRect* rect, ImpellerPaint paint);
  void DisplayListBuilderDrawOval(ImpellerDisplayListBuilder builder, const ImpellerRect* oval_bounds, ImpellerPaint paint);
  void DisplayListBuilderDrawRoundedRect(ImpellerDisplayListBuilder builder, const ImpellerRect* rect, const ImpellerRoundingRadii* radii, ImpellerPaint paint);
  void DisplayListBuilderDrawRoundedRectDifference(ImpellerDisplayListBuilder builder, const ImpellerRect* outer_rect, const ImpellerRoundingRadii* outer_radii, const ImpellerRect* inner_rect, const ImpellerRoundingRadii* inner_radii, ImpellerPaint paint);
  void DisplayListBuilderDrawPath(ImpellerDisplayListBuilder builder, ImpellerPath path, ImpellerPaint paint);
  void DisplayListBuilderDrawShadow(ImpellerDisplayListBuilder builder, ImpellerPath path, const ImpellerColor* color, float elevation, bool occluder_is_transparent, float device_pixel_ratio);
  void DisplayListBuilderDrawTextureRect(ImpellerDisplayListBuilder builder, ImpellerTexture texture, const ImpellerRect* src_rect, const ImpellerRect* dst_rect, ImpellerTextureSampling sampling, ImpellerPaint paint);
  void DisplayListBuilderDrawParagraph(ImpellerDisplayListBuilder builder, ImpellerParagraph paragraph, const ImpellerPoint* point);
  void DisplayListBuilderDrawDisplayList(ImpellerDisplayListBuilder builder, ImpellerDisplayList display_list, float opacity);
  void PaintSetColor(ImpellerPaint paint, const ImpellerColor* color);
  void PaintSetBlendMode(ImpellerPaint paint, ImpellerBlendMode mode);
  void PaintSetDrawStyle(ImpellerPaint paint, ImpellerDrawStyle style);
  void PaintSetStrokeCap(ImpellerPaint paint, ImpellerStrokeCap cap);
  void PaintSetStrokeJoin(ImpellerPaint paint, ImpellerStrokeJoin join);
  void PaintSetStrokeWidth(ImpellerPaint paint, float width);
  void PaintSetStrokeMiter(ImpellerPaint paint, float miter);
  void PaintSetColorFilter(ImpellerPaint paint, ImpellerColorFilter color_filter);
  void PaintSetColorSource(ImpellerPaint paint, ImpellerColorSource color_source);
  void PaintSetImageFilter(ImpellerPaint paint, ImpellerImageFilter image_filter);
  void PaintSetMaskFilter(ImpellerPaint paint, ImpellerMaskFilter mask_filter);
  void PathBuilderMoveTo(ImpellerPathBuilder builder, const ImpellerPoint* location);
  void PathBuilderLineTo(ImpellerPathBuilder builder, const ImpellerPoint* location);
  void PathBuilderQuadraticCurveTo(ImpellerPathBuilder builder, const ImpellerPoint* control_point, const ImpellerPoint* end_point);
  void PathBuilderCubicCurveTo(ImpellerPathBuilder builder, const ImpellerPoint* control_point_1, const ImpellerPoint* control_point_2, const ImpellerPoint* end_point);
  void PathBuilderAddRect(ImpellerPathBuilder builder, const ImpellerRect* rect);
  void PathBuilderAddRoundedRect(ImpellerPathBuilder builder, const ImpellerRect* rect, const ImpellerRoundingRadii* rounding_radii);
  void PathBuilderClose(ImpellerPathBuilder builder);
  void ParagraphStyleSetFontSize(ImpellerParagraphStyle paragraph_style, float size);
  void ParagraphStyleSetFontFamily(ImpellerParagraphStyle paragraph_style, const char* family_name);
  void ParagraphBuilderPushStyle(ImpellerParagraphBuilder paragraph_builder, ImpellerParagraphStyle style);
  void ParagraphBuilderAddText(ImpellerParagraphBuilder paragraph_builder, const uint8_t* data, uint32_t length);
  ImpellerDisplayListBuilder DisplayListBuilderNew(const ImpellerRect* cull_rect);
  ImpellerPaint PaintNew();
  ImpellerPathBuilder PathBuilderNew();
  ImpellerPath PathBuilderTakePathNew(ImpellerPathBuilder builder, ImpellerFillType fill);
  ImpellerColorSource ColorSourceCreateLinearGradientNew(const ImpellerPoint* start_point, const ImpellerPoint* end_point, uint32_t stop_count, const ImpellerColor* colors, const float* stops, ImpellerTileMode tile_mode, const ImpellerMatrix* transformation);
  ImpellerColorSource ColorSourceCreateRadialGradientNew(const ImpellerPoint* center, float radius, uint32_t stop_count, const ImpellerColor* colors, const float* stops, ImpellerTileMode tile_mode, const ImpellerMatrix* transformation);
  ImpellerColorSource ColorSourceCreateImageNew(ImpellerTexture image, ImpellerTileMode horizontal_tile_mode, ImpellerTileMode vertical_tile_mode, ImpellerTextureSampling sampling, const ImpellerMatrix* transformation);
  ImpellerImageFilter ImageFilterCreateBlurNew(float x_sigma, float y_sigma, ImpellerTileMode tile_mode);
  ImpellerColorFilter ColorFilterCreateBlendNew(const ImpellerColor* color, ImpellerBlendMode blend_mode);
  ImpellerColorFilter ColorFilterCreateColorMatrixNew(const ImpellerColorMatrix* color_matrix);
  ImpellerMaskFilter MaskFilterCreateBlurNew(ImpellerBlurStyle style, float sigma);
  ImpellerParagraphStyle ParagraphStyleNew();
  ImpellerParagraphBuilder ParagraphBuilderNew(ImpellerTypographyContext context);
  ImpellerParagraph ParagraphBuilderBuildParagraphNew(ImpellerParagraphBuilder paragraph_builder, float width);
}  // namespace rni::drawop::hook
