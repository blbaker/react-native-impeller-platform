#pragma once
// FP-50: force-included into the painter's translation units (CMake, RNI_DRAWOP_HOOK_SOURCES) so the
// Impeller builder, paint and path calls they make pass through rni::drawop::hook, which forwards
// to the real function and, while a Capture is installed on the thread, logs the call.
// Only .cpp files of the painter may include this: an inline function in a header that calls a hooked
// name would differ between hooked and unhooked translation units.
#include "impeller.h"
#include "scenegraph/DrawOpHookDecl.h"

#define ImpellerDisplayListBuilderRelease ::rni::drawop::hook::DisplayListBuilderRelease
#define ImpellerDisplayListBuilderSave ::rni::drawop::hook::DisplayListBuilderSave
#define ImpellerDisplayListBuilderSaveLayer ::rni::drawop::hook::DisplayListBuilderSaveLayer
#define ImpellerDisplayListBuilderRestore ::rni::drawop::hook::DisplayListBuilderRestore
#define ImpellerDisplayListBuilderScale ::rni::drawop::hook::DisplayListBuilderScale
#define ImpellerDisplayListBuilderRotate ::rni::drawop::hook::DisplayListBuilderRotate
#define ImpellerDisplayListBuilderTranslate ::rni::drawop::hook::DisplayListBuilderTranslate
#define ImpellerDisplayListBuilderTransform ::rni::drawop::hook::DisplayListBuilderTransform
#define ImpellerDisplayListBuilderClipRect ::rni::drawop::hook::DisplayListBuilderClipRect
#define ImpellerDisplayListBuilderClipOval ::rni::drawop::hook::DisplayListBuilderClipOval
#define ImpellerDisplayListBuilderClipRoundedRect ::rni::drawop::hook::DisplayListBuilderClipRoundedRect
#define ImpellerDisplayListBuilderClipPath ::rni::drawop::hook::DisplayListBuilderClipPath
#define ImpellerDisplayListBuilderDrawPaint ::rni::drawop::hook::DisplayListBuilderDrawPaint
#define ImpellerDisplayListBuilderDrawRect ::rni::drawop::hook::DisplayListBuilderDrawRect
#define ImpellerDisplayListBuilderDrawOval ::rni::drawop::hook::DisplayListBuilderDrawOval
#define ImpellerDisplayListBuilderDrawRoundedRect ::rni::drawop::hook::DisplayListBuilderDrawRoundedRect
#define ImpellerDisplayListBuilderDrawRoundedRectDifference ::rni::drawop::hook::DisplayListBuilderDrawRoundedRectDifference
#define ImpellerDisplayListBuilderDrawPath ::rni::drawop::hook::DisplayListBuilderDrawPath
#define ImpellerDisplayListBuilderDrawShadow ::rni::drawop::hook::DisplayListBuilderDrawShadow
#define ImpellerDisplayListBuilderDrawTextureRect ::rni::drawop::hook::DisplayListBuilderDrawTextureRect
#define ImpellerDisplayListBuilderDrawParagraph ::rni::drawop::hook::DisplayListBuilderDrawParagraph
#define ImpellerDisplayListBuilderDrawDisplayList ::rni::drawop::hook::DisplayListBuilderDrawDisplayList
#define ImpellerPaintSetColor ::rni::drawop::hook::PaintSetColor
#define ImpellerPaintSetBlendMode ::rni::drawop::hook::PaintSetBlendMode
#define ImpellerPaintSetDrawStyle ::rni::drawop::hook::PaintSetDrawStyle
#define ImpellerPaintSetStrokeCap ::rni::drawop::hook::PaintSetStrokeCap
#define ImpellerPaintSetStrokeJoin ::rni::drawop::hook::PaintSetStrokeJoin
#define ImpellerPaintSetStrokeWidth ::rni::drawop::hook::PaintSetStrokeWidth
#define ImpellerPaintSetStrokeMiter ::rni::drawop::hook::PaintSetStrokeMiter
#define ImpellerPaintSetColorFilter ::rni::drawop::hook::PaintSetColorFilter
#define ImpellerPaintSetColorSource ::rni::drawop::hook::PaintSetColorSource
#define ImpellerPaintSetImageFilter ::rni::drawop::hook::PaintSetImageFilter
#define ImpellerPaintSetMaskFilter ::rni::drawop::hook::PaintSetMaskFilter
#define ImpellerPathBuilderMoveTo ::rni::drawop::hook::PathBuilderMoveTo
#define ImpellerPathBuilderLineTo ::rni::drawop::hook::PathBuilderLineTo
#define ImpellerPathBuilderQuadraticCurveTo ::rni::drawop::hook::PathBuilderQuadraticCurveTo
#define ImpellerPathBuilderCubicCurveTo ::rni::drawop::hook::PathBuilderCubicCurveTo
#define ImpellerPathBuilderAddRect ::rni::drawop::hook::PathBuilderAddRect
#define ImpellerPathBuilderAddRoundedRect ::rni::drawop::hook::PathBuilderAddRoundedRect
#define ImpellerPathBuilderClose ::rni::drawop::hook::PathBuilderClose
#define ImpellerParagraphStyleSetFontSize ::rni::drawop::hook::ParagraphStyleSetFontSize
#define ImpellerParagraphStyleSetFontFamily ::rni::drawop::hook::ParagraphStyleSetFontFamily
#define ImpellerParagraphBuilderPushStyle ::rni::drawop::hook::ParagraphBuilderPushStyle
#define ImpellerParagraphBuilderAddText ::rni::drawop::hook::ParagraphBuilderAddText
#define ImpellerDisplayListBuilderNew ::rni::drawop::hook::DisplayListBuilderNew
#define ImpellerPaintNew ::rni::drawop::hook::PaintNew
#define ImpellerPathBuilderNew ::rni::drawop::hook::PathBuilderNew
#define ImpellerPathBuilderTakePathNew ::rni::drawop::hook::PathBuilderTakePathNew
#define ImpellerColorSourceCreateLinearGradientNew ::rni::drawop::hook::ColorSourceCreateLinearGradientNew
#define ImpellerColorSourceCreateRadialGradientNew ::rni::drawop::hook::ColorSourceCreateRadialGradientNew
#define ImpellerColorSourceCreateImageNew ::rni::drawop::hook::ColorSourceCreateImageNew
#define ImpellerImageFilterCreateBlurNew ::rni::drawop::hook::ImageFilterCreateBlurNew
#define ImpellerColorFilterCreateBlendNew ::rni::drawop::hook::ColorFilterCreateBlendNew
#define ImpellerColorFilterCreateColorMatrixNew ::rni::drawop::hook::ColorFilterCreateColorMatrixNew
#define ImpellerMaskFilterCreateBlurNew ::rni::drawop::hook::MaskFilterCreateBlurNew
#define ImpellerParagraphStyleNew ::rni::drawop::hook::ParagraphStyleNew
#define ImpellerParagraphBuilderNew ::rni::drawop::hook::ParagraphBuilderNew
#define ImpellerParagraphBuilderBuildParagraphNew ::rni::drawop::hook::ParagraphBuilderBuildParagraphNew
