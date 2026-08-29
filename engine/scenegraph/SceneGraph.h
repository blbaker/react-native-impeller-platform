// SceneGraph — the retained render tree. Fabric hands us flat mutation lists;
// this keeps a tag-keyed node tree and paints it into an ImpellerDisplayList.
//
// Threading: mutations arrive on the JS thread, paint happens on whoever owns
// the surface. One mutex guards the tree, so a paint mid-commit sees a
// consistent tree rather than a half-applied transaction.
#pragma once

#include <react/renderer/components/text/ParagraphProps.h>
#include <react/renderer/components/text/ParagraphState.h>
#include <react/renderer/components/view/ViewProps.h>
#include <react/renderer/core/LayoutMetrics.h>
#include <react/renderer/mounting/ShadowViewMutation.h>

#include <cstdint>
#include <array>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "impeller.h"

namespace rni {

// Everything we need to paint one node, snapshotted from its ShadowView. We
// copy rather than hold Props::Shared so paint never dereferences a prop
// object the JS thread is concurrently replacing.
struct SceneNode {
  facebook::react::Tag tag{};
  std::string componentName;
  facebook::react::LayoutMetrics layoutMetrics{};

  bool hasBackgroundColor{false};
  float bg[4]{0, 0, 0, 0};   // r,g,b,a
  float opacity{1.0f};

  // Borders, PER EDGE. P2 resolved RN's border cascade and then used the left
  // edge for all four, which paints a uniform frame — a frame that looks
  // completely reasonable in a screenshot and is wrong for every app that sets
  // a single edge. Order below is top, right, bottom, left throughout.
  float borderWidths[4]{0, 0, 0, 0};
  bool hasBorderColors[4]{false, false, false, false};
  float borderColors[4][4]{};

  // Radii, PER CORNER, in Impeller's field order: TL, BL, TR, BR (NOT
  // clockwise). P2 collapsed these to a single `all` value, so one rounded
  // corner drew as four.
  float borderRadii[4]{0, 0, 0, 0};

  // Linear gradient (`experimental_backgroundImage`). Painted UNDER the
  // background colour rule: when a gradient is present it replaces the flat
  // fill, matching CSS painting order.
  bool hasGradient{false};
  float gradStart[2]{0, 0};  // in node-local coordinates
  float gradEnd[2]{0, 0};
  std::vector<float> gradStops;         // 0..1, ascending
  std::vector<std::array<float, 4>> gradColors;

  // Resolved transform matrix (column-major 4x4, RN's own layout), already
  // including transform-origin. Identity when the node has no transform.
  bool hasTransform{false};
  std::array<float, 16> transform{{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}};

  bool overflowHidden{false};

  // Text (Paragraph nodes). Laid out at mount time from ParagraphState so the
  // painted text is the same object that was measured.
  bool isParagraph{false};
  std::string text;
  float fontSize{14};
  float textColor[4]{0, 0, 0, 1};
  // numberOfLines. Must be applied at PAINT time as well as measure time, or a
  // clamped label measures one line and paints three.
  int maxLines{0};

  // RNSVGPath (P9-B2). `d` is re-parsed into geometry only when it changes —
  // see SvgPath.h. fillOpacity is kept SEPARATE from node.opacity (which
  // already holds the resolved ViewProps opacity for this node): the paint
  // path multiplies clamp(fillOpacity) * clamp(opacity), because the HostApp
  // mark's grey ramp is fillOpacity varying PER PATH while opacity is the
  // ordinary View cascade.
  bool isSvgPath{false};
  std::string svgD;
  bool svgHasFill{false};
  float svgFillColor[4]{0, 0, 0, 1};
  float svgFillOpacity{1.0f};
  bool svgFillEvenOdd{false};

  // ⛔ SVG's transform is a 2D AFFINE OF SIX FLOATS, not the 16-float 4x4 the
  // View `transform` prop carries. react-native-svg's extractTransform()
  // returns COLUMN-MAJOR [a, b, c, d, tx, ty] (see its
  // lib/extract/extractTransform.ts, which builds exactly
  // [t[0], t[3], t[1], t[4], t[2], t[5]] from a parsed transform string), so
  // mapping it as a 4x4 would silently scramble the axes rather than fail.
  //
  // This applies to EVERY RNSVG element -- Group, Path, and every shape --
  // because they all inherit the same `matrix` prop.
  bool hasSvgMatrix{false};
  float svgMatrix[6]{1, 0, 0, 1, 0, 0};  // a, b, c, d, tx, ty

  std::vector<facebook::react::Tag> children;
  facebook::react::Tag parent{};
};

class SceneGraph {
 public:
  explicit SceneGraph(ImpellerTypographyContext typography);

  // Applies one MountingTransaction's mutations, in order.
  void applyMutations(const facebook::react::ShadowViewMutation::List& mutations,
                      bool log = false);

  // Paints the whole tree into `builder`. Returns the number of nodes drawn —
  // a caller can tell "painted nothing" from "painted an empty-looking frame",
  // which are different bugs.
  //
  // ⛔ LAYOUT IS IN POINTS; THE SURFACE IS IN DEVICE PIXELS.
  // Every frame/origin in the tree comes out of Yoga in POINTS, so painting
  // them straight onto a 2x surface would fill only the top-left quarter of
  // it. pointScaleFactor is applied as a root transform, which is also what
  // makes text and vector geometry rasterise at full device resolution rather
  // than being upscaled after the fact.
  int paint(ImpellerDisplayListBuilder builder, float pointScaleFactor = 1.0f);

  // Diagnostics: node count and root tag, for gates that need to distinguish
  // "no tree" from "tree present but invisible".
  size_t nodeCount();
  std::string describe();

  // One `node_frame=<Component>,<tag>,<x>,<y>,<w>,<h>` line per node.
  //
  // This exists because PAINTED INK DOES NOT PROVE MEASUREMENT. A <Text> whose
  // TextLayoutManager returns 0x0 still paints its glyphs (the painter draws at
  // the node's origin), so an ink-based probe passes while Yoga has laid the
  // node out as a zero-sized box and every sibling is positioned wrongly. The
  // frame is the only signal that separates the two.
  std::string frameReport();

 private:
  void updateFromShadowView(SceneNode& node,
                            const facebook::react::ShadowView& view);
  void paintNode(ImpellerDisplayListBuilder builder,
                 const SceneNode& node,
                 float originX,
                 float originY);
  // Split out of paintNode because per-edge borders are a whole geometry
  // problem: a stroked rect cannot express four colours and straddles the path,
  // so each edge is drawn as its own mitred quad.
  void paintBorders(ImpellerDisplayListBuilder builder,
                    const SceneNode& node,
                    float x, float y, float w, float h,
                    const ImpellerRoundingRadii& radii,
                    bool rounded);

  std::mutex mutex_;
  int painted_{0};  // reset per paint(); incremented in paintNode()
  std::unordered_map<facebook::react::Tag, SceneNode> nodes_;
  std::vector<facebook::react::Tag> roots_;
  ImpellerTypographyContext typography_{nullptr};
};

}  // namespace rni
