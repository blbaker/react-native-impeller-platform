// FP-50: backgrounds, borders and corner radii. Each case builds one canned mutation list, paints it
// and asserts the full draw-op log (no transform/clip suffix unless the case is about them).
#include "tests/SceneFixture.h"
#include "tests/TestHarness.h"

namespace rni::test {

RNI_TEST(background_fills_the_frame) {
  TestScene s;
  s.View(1, R"({"backgroundColor":4294901760})", 10, 20, 100, 50);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRect rect(10,20,100,50) paint(#ff0000ff)
)ops");
}

RNI_TEST(transparent_background_paints_nothing) {
  TestScene s;
  s.View(1, R"({"backgroundColor":0})", 10, 20, 100, 50);
  EXPECT_TEXT(s.Ops(), R"()");
}

// processColor('transparent') is 0. A border edge set to it must paint nothing, not the opaque black
// an unset colour falls back to (the triangle of a CSS-style wedge).
RNI_TEST(transparent_border_edge_paints_nothing) {
  TestScene s;
  s.View(1, R"({"borderBottomWidth":40,"borderBottomColor":4294901760,"borderRightWidth":40,"borderRightColor":0})",
         10, 10, 40, 40);
  EXPECT_TEXT(s.Ops(), R"ops(DrawPath path[M(50,50) L(10,50) L(10,10) L(10,10) Z nonzero] paint(#ff0000ff)
)ops");
}

RNI_TEST(uniform_border_paints_four_mitred_quads) {
  TestScene s;
  s.View(1, R"({"borderWidth":4,"borderColor":4278190335})", 10, 10, 100, 60);
  EXPECT_TEXT(s.Ops(), R"ops(DrawPath path[M(10,10) L(110,10) L(106,14) L(14,14) Z nonzero] paint(#0000ffff)
DrawPath path[M(110,10) L(110,70) L(106,66) L(106,14) Z nonzero] paint(#0000ffff)
DrawPath path[M(110,70) L(10,70) L(14,66) L(106,66) Z nonzero] paint(#0000ffff)
DrawPath path[M(10,70) L(10,10) L(14,14) L(14,66) Z nonzero] paint(#0000ffff)
)ops");
}

RNI_TEST(border_without_width_paints_nothing) {
  TestScene s;
  s.View(1, R"({"borderColor":4278190335})", 10, 10, 100, 60);
  EXPECT_TEXT(s.Ops(), R"()");
}

RNI_TEST(per_side_border_colors_paint_four_quads) {
  TestScene s;
  s.View(1, R"({"borderWidth":3,"borderTopColor":4294901760,"borderRightColor":4278255360,
               "borderBottomColor":4278190335,"borderLeftColor":4294967040})", 10, 10, 100, 60);
  EXPECT_TEXT(s.Ops(), R"ops(DrawPath path[M(10,10) L(110,10) L(107,13) L(13,13) Z nonzero] paint(#ff0000ff)
DrawPath path[M(110,10) L(110,70) L(107,67) L(107,13) Z nonzero] paint(#00ff00ff)
DrawPath path[M(110,70) L(10,70) L(13,67) L(107,67) Z nonzero] paint(#0000ffff)
DrawPath path[M(10,70) L(10,10) L(13,13) L(13,67) Z nonzero] paint(#ffff00ff)
)ops");
}

RNI_TEST(dashed_border_paints_dash_segments) {
  TestScene s;
  s.View(1, R"({"borderWidth":2,"borderStyle":"dashed","borderColor":4278190080})", 10, 10, 100, 40);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRect rect(11,10,6,2) paint(#000000ff)
DrawRect rect(23,10,6,2) paint(#000000ff)
DrawRect rect(35,10,6,2) paint(#000000ff)
DrawRect rect(47,10,6,2) paint(#000000ff)
DrawRect rect(59,10,6,2) paint(#000000ff)
DrawRect rect(71,10,6,2) paint(#000000ff)
DrawRect rect(83,10,6,2) paint(#000000ff)
DrawRect rect(95,10,6,2) paint(#000000ff)
DrawRect rect(107,10,2,2) paint(#000000ff)
DrawRect rect(108,10,2,2) paint(#000000ff)
DrawRect rect(108,11,2,4) paint(#000000ff)
DrawRect rect(108,21,2,6) paint(#000000ff)
DrawRect rect(108,33,2,6) paint(#000000ff)
DrawRect rect(108,45,2,4) paint(#000000ff)
DrawRect rect(108,48,2,2) paint(#000000ff)
DrawRect rect(107,48,2,2) paint(#000000ff)
DrawRect rect(95,48,6,2) paint(#000000ff)
DrawRect rect(83,48,6,2) paint(#000000ff)
DrawRect rect(71,48,6,2) paint(#000000ff)
DrawRect rect(59,48,6,2) paint(#000000ff)
DrawRect rect(47,48,6,2) paint(#000000ff)
DrawRect rect(35,48,6,2) paint(#000000ff)
DrawRect rect(23,48,6,2) paint(#000000ff)
DrawRect rect(11,48,6,2) paint(#000000ff)
DrawRect rect(10,37,2,6) paint(#000000ff)
DrawRect rect(10,25,2,6) paint(#000000ff)
DrawRect rect(10,13,2,6) paint(#000000ff)
)ops");
}

RNI_TEST(uniform_radius_is_one_circular_rrect) {
  TestScene s;
  s.View(1, R"({"backgroundColor":4294967295,"borderRadius":8})", 10, 10, 100, 60);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRRect rect(10,10,100,60) r=8 paint(#ffffffff)
)ops");
}

RNI_TEST(per_corner_radii_keep_their_corners) {
  TestScene s;
  s.View(1, R"({"backgroundColor":4294967295,"borderTopLeftRadius":10,"borderBottomRightRadius":4})",
         10, 10, 100, 60);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRRect rect(10,10,100,60) r(tl=10 tr=0 br=4 bl=0) paint(#ffffffff)
)ops");
}

RNI_TEST(radius_larger_than_half_the_box_is_clamped) {
  TestScene s;
  s.View(1, R"({"backgroundColor":4294967295,"borderRadius":500})", 10, 10, 100, 60);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRRect rect(10,10,100,60) r=30 paint(#ffffffff)
)ops");
}

RNI_TEST(rounded_uniform_border_is_a_stroked_rrect_on_the_inset_box) {
  TestScene s;
  s.View(1, R"({"borderWidth":4,"borderColor":4278190335,"borderRadius":12})", 10, 10, 100, 60);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRRect rect(12,12,96,56) r=10 paint(#0000ffff stroke w=4 cap=0 join=0 miter=4)
)ops");
}

RNI_TEST(background_then_border_in_paint_order) {
  TestScene s;
  s.View(1, R"({"backgroundColor":4294967295,"borderWidth":2,"borderColor":4278190080,"borderRadius":6})",
         10, 10, 100, 60);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRRect rect(10,10,100,60) r=6 paint(#ffffffff)
DrawRRect rect(11,11,98,58) r=5 paint(#000000ff stroke w=2 cap=0 join=0 miter=4)
)ops");
}

RNI_TEST(percent_radius_on_a_square_resolves_to_half_the_side) {
  TestScene s;
  s.View(1, R"({"backgroundColor":4294967295,"borderRadius":"50%"})", 10, 10, 60, 60);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRRect rect(10,10,60,60) r=30 paint(#ffffffff)
)ops");
}

}  // namespace rni::test
