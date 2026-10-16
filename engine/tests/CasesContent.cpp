// FP-50: text runs, svg, scale, and the update/remove paths.
#include "tests/SceneFixture.h"
#include "tests/TestHarness.h"

namespace rni::test {

RNI_TEST(text_run_draws_one_paragraph_at_its_origin) {
  TestScene s;
  s.Text(1, "Hello", 10, 20, 100, 20, TextStyle{16, "", 0xFF000000});
  EXPECT_TEXT(s.Ops(), R"ops(DrawParagraph at=(10,20) text("Hello"@16 width=100)
)ops");
}

RNI_TEST(text_size_and_family_reach_the_paragraph_style) {
  TestScene s;
  s.Text(1, "Sized", 0, 0, 100, 30, TextStyle{24, "Roboto", 0xFF112233});
  EXPECT_TEXT(s.Ops(), R"ops(DrawParagraph at=(0,0) text("Sized"@24 Roboto width=100)
)ops");
}

RNI_TEST(text_inside_overflow_hidden_is_clipped) {
  TestScene s;
  const Tag v = s.View(1, R"({"overflow":"hidden"})", 10, 10, 60, 20);
  s.Text(v, "A long line of text", 0, 0, 200, 20);
  EXPECT_ORDER(s.Ops(), "Save", "ClipRect", "DrawParagraph", "Restore");
}

RNI_TEST(svg_path_draws_the_path_commands) {
  TestScene s;
  const Tag svg = s.Add("RNSVGSvgView", 1, R"({"bbWidth":"100","bbHeight":"100","minX":0,"minY":0,"vbWidth":100,
                         "vbHeight":100,"align":"xMidYMid","meetOrSlice":0})", 0, 0, 100, 100);
  s.Add("RNSVGPath", svg, R"({"d":"M10 10 L90 10 L90 90 Z","fill":{"type":0,"payload":4278190335}})", 0, 0, 100, 100);
  EXPECT_TEXT(s.Ops(), R"ops(Save
  ClipRect rect(0,0,100,100)
  Transform I
  Save
    Translate 0,0
    DrawPath path[M(10,10) L(90,10) L(90,90) Z nonzero] paint(#0000ffff)
  Restore
Restore
)ops");
}

RNI_TEST(svg_stroke_sets_the_stroke_style) {
  TestScene s;
  const Tag svg = s.Add("RNSVGSvgView", 1, R"({"bbWidth":"100","bbHeight":"100","minX":0,"minY":0,"vbWidth":100,
                         "vbHeight":100,"align":"xMidYMid","meetOrSlice":0})", 0, 0, 100, 100);
  s.Add("RNSVGPath", svg, R"({"d":"M10 10 L90 90","stroke":{"type":0,"payload":4294901760},"strokeWidth":"4"})",
        0, 0, 100, 100);
  EXPECT_TEXT(s.Ops(), R"ops(Save
  ClipRect rect(0,0,100,100)
  Transform I
  Save
    Translate 0,0
    DrawPath path[M(10,10) L(90,90) nonzero] paint(#ff0000ff stroke w=4 cap=0 join=0 miter=4)
  Restore
Restore
)ops");
}

RNI_TEST(point_scale_two_scales_the_root) {
  TestScene s;
  s.View(1, R"({"backgroundColor":4294901760})", 10, 10, 50, 50);
  EXPECT_TEXT(s.Ops(true, 2.0f), R"ops(Save
  Scale 2,2
  DrawRect rect(10,10,50,50) paint(#ff0000ff) | ctm=[2 0 0 2 0 0] clip=none
Restore
)ops");
}

RNI_TEST(update_changes_the_next_frame) {
  TestScene s;
  const Tag v = s.View(1, R"({"backgroundColor":4294901760})", 10, 10, 50, 50);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRect rect(10,10,50,50) paint(#ff0000ff)
)ops");
  s.Update(v, R"({"backgroundColor":4278190335})");
  EXPECT_TEXT(s.Ops(), R"ops(DrawRect rect(10,10,50,50) paint(#0000ffff)
)ops");
}

RNI_TEST(removed_node_stops_painting) {
  TestScene s;
  const Tag v = s.View(1, R"({"backgroundColor":4294901760})", 10, 10, 50, 50);
  s.View(1, R"({"backgroundColor":4278190335})", 70, 10, 50, 50);
  s.Ops();
  s.Remove(v);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRect rect(70,10,50,50) paint(#0000ffff)
)ops");
}

RNI_TEST(outline_draws_outside_the_box) {
  TestScene s;
  s.View(1, R"({"outlineWidth":3,"outlineColor":4278190335,"outlineOffset":2,"outlineStyle":"solid"})",
         20, 20, 60, 40);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRRect rect(16.5,16.5,67,47) r=0 paint(#0000ffff stroke w=3 cap=0 join=0 miter=4)
)ops");
}

}  // namespace rni::test
