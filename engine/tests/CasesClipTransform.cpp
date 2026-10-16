// FP-50: overflow clips, transforms and paint order.
#include "tests/SceneFixture.h"
#include "tests/TestHarness.h"

namespace rni::test {

RNI_TEST(overflow_hidden_clips_children_to_the_box) {
  TestScene s;
  const Tag v = s.View(1, R"({"overflow":"hidden"})", 10, 10, 100, 60);
  s.View(v, R"({"backgroundColor":4294901760})", -20, 0, 200, 30);
  EXPECT_TEXT(s.Ops(true), R"ops(Save
  ClipRect rect(10,10,100,60) | ctm=I clip=(10,10,110,70)
  DrawRect rect(-10,10,200,30) paint(#ff0000ff) | ctm=I clip=(10,10,110,70)
Restore
)ops");
}

RNI_TEST(overflow_visible_does_not_clip) {
  TestScene s;
  const Tag v = s.View(1, R"({"overflow":"visible"})", 10, 10, 100, 60);
  s.View(v, R"({"backgroundColor":4294901760})", -20, 0, 200, 30);
  EXPECT_ABSENT(s.Ops(), "Clip");
}

RNI_TEST(overflow_hidden_with_radius_clips_to_the_rrect) {
  TestScene s;
  const Tag v = s.View(1, R"({"overflow":"hidden","borderRadius":12})", 10, 10, 100, 60);
  s.View(v, R"({"backgroundColor":4294901760})", 0, 0, 100, 30);
  EXPECT_TEXT(s.Ops(), R"ops(Save
  ClipRRect rect(10,10,100,60) r=12
  DrawRect rect(10,10,100,30) paint(#ff0000ff)
Restore
)ops");
}

RNI_TEST(clip_is_set_before_the_children_draw) {
  TestScene s;
  const Tag v = s.View(1, R"({"overflow":"hidden"})", 10, 10, 100, 60);
  s.View(v, R"({"backgroundColor":4294901760})", 0, 0, 50, 50);
  EXPECT_ORDER(s.Ops(), "Save", "ClipRect", "DrawRect", "Restore");
}

RNI_TEST(nested_clips_intersect) {
  TestScene s;
  const Tag a = s.View(1, R"({"overflow":"hidden"})", 0, 0, 100, 100);
  const Tag b = s.View(a, R"({"overflow":"hidden"})", 50, 50, 100, 100);
  s.View(b, R"({"backgroundColor":4294901760})", 0, 0, 100, 100);
  EXPECT_TEXT(s.Ops(true), R"ops(Save
  ClipRect rect(0,0,100,100) | ctm=I clip=(0,0,100,100)
  Save
    ClipRect rect(50,50,100,100) | ctm=I clip=(50,50,100,100)
    DrawRect rect(50,50,100,100) paint(#ff0000ff) | ctm=I clip=(50,50,100,100)
  Restore
Restore
)ops");
}

RNI_TEST(translate_transform_moves_the_children) {
  TestScene s;
  const Tag v = s.View(1, R"({"transform":[{"translateX":30},{"translateY":10}]})", 10, 10, 100, 60);
  s.View(v, R"({"backgroundColor":4294901760})", 0, 0, 50, 50);
  EXPECT_TEXT(s.Ops(true), R"ops(Save
  Transform [1 0 0 1 60 40]
  Transform [1 0 0 1 30 10]
  Transform [1 0 0 1 -60 -40]
  DrawRect rect(10,10,50,50) paint(#ff0000ff) | ctm=[1 0 0 1 30 10] clip=none
Restore
)ops");
}

RNI_TEST(rotate_and_scale_compose_in_order) {
  TestScene s;
  const Tag v = s.View(1, R"({"transform":[{"rotate":"90deg"},{"scale":2}]})", 10, 10, 100, 60);
  s.View(v, R"({"backgroundColor":4294901760})", 0, 0, 20, 20);
  EXPECT_TEXT(s.Ops(true), R"ops(Save
  Transform [1 0 0 1 60 40]
  Transform m4[0 2 0 0 -2 0 0 0 0 0 2 0 0 0 0 1]
  Transform [1 0 0 1 -60 -40]
  DrawRect rect(10,10,20,20) paint(#ff0000ff) | ctm=m4[0 2 0 0 -2 0 0 0 0 0 2 0 140 -80 0 1] clip=none
Restore
)ops");
}

RNI_TEST(transform_origin_shifts_the_pivot) {
  TestScene s;
  const Tag v = s.View(1, R"({"transform":[{"scale":2}],"transformOrigin":["0%","0%",0]})", 10, 10, 100, 60);
  s.View(v, R"({"backgroundColor":4294901760})", 0, 0, 20, 20);
  EXPECT_TEXT(s.Ops(true), R"ops(Save
  Transform [1 0 0 1 60 40]
  Transform m4[2 0 0 0 0 2 0 0 0 0 2 0 50 30 0 1]
  Transform [1 0 0 1 -60 -40]
  DrawRect rect(10,10,20,20) paint(#ff0000ff) | ctm=m4[2 0 0 0 0 2 0 0 0 0 2 0 -10 -10 0 1] clip=none
Restore
)ops");
}

RNI_TEST(siblings_paint_in_insertion_order) {
  TestScene s;
  s.View(1, R"({"backgroundColor":4294901760})", 0, 0, 50, 50);
  s.View(1, R"({"backgroundColor":4278255360})", 10, 10, 50, 50);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRect rect(0,0,50,50) paint(#ff0000ff)
DrawRect rect(10,10,50,50) paint(#00ff00ff)
)ops");
}

RNI_TEST(child_paints_after_its_parent_background) {
  TestScene s;
  const Tag v = s.View(1, R"({"backgroundColor":4294901760})", 0, 0, 80, 80);
  s.View(v, R"({"backgroundColor":4278255360})", 10, 10, 20, 20);
  EXPECT_TEXT(s.Ops(true), R"ops(DrawRect rect(0,0,80,80) paint(#ff0000ff) | ctm=I clip=none
DrawRect rect(10,10,20,20) paint(#00ff00ff) | ctm=I clip=none
)ops");
}

RNI_TEST(display_none_hides_the_subtree) {
  TestScene s;
  const Tag v = s.View(1, R"({"display":"none"})", 0, 0, 50, 50);
  s.View(v, R"({"backgroundColor":4294901760})", 0, 0, 20, 20);
  EXPECT_TEXT(s.Ops(), R"ops(DrawRect rect(0,0,20,20) paint(#ff0000ff)
)ops");
}

}  // namespace rni::test
