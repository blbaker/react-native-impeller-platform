// FP-50: shadows, opacity groups, blend modes, filters and gradients.
#include "tests/SceneFixture.h"
#include "tests/TestHarness.h"

namespace rni::test {

RNI_TEST(box_shadow_paints_before_the_background) {
  TestScene s;
  s.View(1, R"({"backgroundColor":4294967295,"boxShadow":[{"offsetX":2,"offsetY":3,"blurRadius":4,"color":4278190080}]})",
         20, 20, 80, 50);
  EXPECT_TEXT(s.Ops(), R"ops(Save
  ClipRect rect(20,20,80,50) diff
  DrawRect rect(22,23,80,50) paint(#000000ff mf=maskblur(0,2))
Restore
DrawRect rect(20,20,80,50) paint(#ffffffff)
)ops");
}

RNI_TEST(elevation_draws_one_shadow_for_the_rounded_box) {
  TestScene s;
  s.View(1, R"({"backgroundColor":4294967295,"borderRadius":8,"elevation":6})", 20, 20, 80, 50);
  EXPECT_TEXT(s.Ops(), R"ops(DrawShadow path[rrect(20,20,80,50) r=8 nonzero] #000000ff elev=6 dpr=1
DrawRRect rect(20,20,80,50) r=8 paint(#ffffffff)
)ops");
}

RNI_TEST(ios_shadow_props_need_an_opacity) {
  TestScene s;
  s.View(1, R"({"backgroundColor":4294967295,"shadowColor":4278190080,"shadowOpacity":0,"shadowRadius":5})",
         20, 20, 80, 50);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRect rect(20,20,80,50) paint(#ffffffff)
)ops");
}

// Colour 0 is processColor('transparent'). Each case below used to read it as "unset" and paint the
// unset fallback, opaque black.
RNI_TEST(transparent_outline_paints_nothing) {
  TestScene s;
  s.View(1, R"({"backgroundColor":4294967295,"outlineWidth":10,"outlineStyle":"solid","outlineColor":0})",
         20, 20, 40, 40);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRect rect(20,20,40,40) paint(#ffffffff)
)ops");
}

RNI_TEST(transparent_ios_shadow_paints_nothing) {
  TestScene s;
  s.View(1, R"({"backgroundColor":4294967295,"shadowColor":0,"shadowOpacity":1,"shadowRadius":0,
               "shadowOffset":{"width":20,"height":20}})", 20, 20, 40, 40);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRect rect(20,20,40,40) paint(#ffffffff)
)ops");
}

RNI_TEST(transparent_box_shadow_paints_nothing) {
  TestScene s;
  s.View(1, R"({"backgroundColor":4294967295,"boxShadow":[{"offsetX":20,"offsetY":20,"blurRadius":0,"color":0}]})",
         20, 20, 40, 40);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRect rect(20,20,40,40) paint(#ffffffff)
)ops");
}

RNI_TEST(transparent_drop_shadow_paints_nothing) {
  TestScene s;
  const Tag v = s.View(1, R"({"filter":[{"dropShadow":{"offsetX":20,"offsetY":20,"standardDeviation":0,"color":0}}]})",
                       20, 20, 40, 40);
  s.View(v, R"({"backgroundColor":4294967295})", 0, 0, 40, 40);
  // The shadow pass still runs, tinted with an alpha-0 colour (source-in), so it paints nothing.
  EXPECT_TEXT(s.Ops(), R"ops(Save
  Translate 20,20
  SaveLayer rect(-100000,-100000,200000,200000) paint(#000000ff cf=blend(#00000100,source-in))
    DrawRect rect(20,20,40,40) paint(#ffffffff)
  Restore
Restore
DrawRect rect(20,20,40,40) paint(#ffffffff)
)ops");
}

RNI_TEST(opacity_half_wraps_the_subtree_in_one_save_layer) {
  TestScene s;
  const Tag v = s.View(1, R"({"opacity":0.5})", 10, 10, 100, 60);
  s.View(v, R"({"backgroundColor":4294901760})", 0, 0, 50, 50);
  EXPECT_TEXT(s.Ops(), R"ops(SaveLayer rect(-100000,-100000,200000,200000) paint(#ffffff80)
  DrawRect rect(10,10,50,50) paint(#ff0000ff)
Restore
)ops");
}

RNI_TEST(opacity_one_adds_no_layer) {
  TestScene s;
  const Tag v = s.View(1, R"({"opacity":1})", 10, 10, 100, 60);
  s.View(v, R"({"backgroundColor":4294901760})", 0, 0, 50, 50);
  EXPECT_ABSENT(s.Ops(), "SaveLayer");
}

RNI_TEST(opacity_zero_still_records_a_transparent_layer) {
  TestScene s;
  const Tag v = s.View(1, R"({"opacity":0})", 10, 10, 100, 60);
  s.View(v, R"({"backgroundColor":4294901760})", 0, 0, 50, 50);
  EXPECT_TEXT(s.Ops(), R"ops(SaveLayer rect(-100000,-100000,200000,200000) paint(#ffffff00)
  DrawRect rect(10,10,50,50) paint(#ff0000ff)
Restore
)ops");
}

RNI_TEST(nested_opacity_makes_nested_layers) {
  TestScene s;
  const Tag outer = s.View(1, R"({"opacity":0.5})", 0, 0, 100, 100);
  const Tag inner = s.View(outer, R"({"opacity":0.5})", 10, 10, 80, 80);
  s.View(inner, R"({"backgroundColor":4278190335})", 0, 0, 40, 40);
  EXPECT_TEXT(s.Ops(), R"ops(SaveLayer rect(-100000,-100000,200000,200000) paint(#ffffff80)
  SaveLayer rect(-100000,-100000,200000,200000) paint(#ffffff80)
    DrawRect rect(10,10,40,40) paint(#0000ffff)
  Restore
Restore
)ops");
}

RNI_TEST(mix_blend_mode_multiply_sets_the_layer_blend) {
  TestScene s;
  const Tag v = s.View(1, R"({"mixBlendMode":"multiply"})", 10, 10, 100, 60);
  s.View(v, R"({"backgroundColor":4294901760})", 0, 0, 50, 50);
  EXPECT_TEXT(s.Ops(), R"ops(SaveLayer rect(-100000,-100000,200000,200000) paint(#000000ff blend=multiply)
  DrawRect rect(10,10,50,50) paint(#ff0000ff)
Restore
)ops");
}

RNI_TEST(blur_filter_puts_a_blur_on_the_layer_paint) {
  TestScene s;
  const Tag v = s.View(1, R"({"filter":[{"blur":3}]})", 10, 10, 100, 60);
  s.View(v, R"({"backgroundColor":4294901760})", 0, 0, 50, 50);
  EXPECT_TEXT(s.Ops(), R"ops(SaveLayer rect(-100000,-100000,200000,200000) paint(#000000ff imf=blur(3,3 tile=3))
  DrawRect rect(10,10,50,50) paint(#ff0000ff)
Restore
)ops");
}

RNI_TEST(linear_gradient_background_uses_a_gradient_source) {
  TestScene s;
  s.View(1, R"({"experimental_backgroundImage":[{"type":"linear-gradient","direction":{"type":"angle","value":90},
               "colorStops":[{"color":4278190335,"position":"0%"},{"color":4294901760,"position":"100%"}]}]})", 10, 10, 100, 60);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRect rect(10,10,100,60) paint(#000000ff src=linear((10,40)->(110,40) stops=[#0000ffff@0 #ff0000ff@1] tile=0))
)ops");
}

}  // namespace rni::test
