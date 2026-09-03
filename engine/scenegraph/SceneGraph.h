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
  // The node's Fabric event emitter, captured from the ShadowView during
  // mounting. Held as the base EventEmitter (what ShadowView carries); touch
  // dispatch downcasts to TouchEventEmitter. Null for nodes whose descriptor
  // does not emit touches, so every use must check.
  facebook::react::EventEmitter::Shared eventEmitter{};
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

  // Stroke. Independent of fill: an SVG element may have either, both, or
  // neither, and a stroked-only shape with no fill is ordinary in real art.
  bool svgHasStroke{false};
  float svgStrokeColor[4]{0, 0, 0, 1};
  float svgStrokeOpacity{1.0f};
  float svgStrokeWidth{1.0f};
  int svgStrokeLinecap{0};   // 0 butt, 1 round, 2 square  (rnsvg encoding)
  int svgStrokeLinejoin{0};  // 0 miter, 1 round, 2 bevel  (rnsvg encoding)
  float svgStrokeMiterlimit{4.0f};

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

  // ⛔ A GRADIENT FILL IS A REFERENCE, NOT A COLOUR.
  //
  // extractBrush() emits {type: 0, payload} for a plain colour but
  // {type: 1, brushRef: "<id>"} for `fill="url(#id)"`. The <LinearGradient>
  // itself is a SEPARATE node elsewhere in the tree (usually inside <Defs>,
  // which paints nothing), so resolving it means a registry keyed by the def's
  // `name` prop -- it cannot be read off the shape's own props.
  bool svgFillIsRef{false};
  std::string svgFillRef;
  bool svgStrokeIsRef{false};
  std::string svgStrokeRef;

  // ⛔ A DEFINITION SUBTREE IS NOT IN THE PAINT ORDER.
  //
  // <Defs> and <Symbol> are containers whose children are DECLARED, not drawn.
  // The painter recurses into every child unconditionally, so without this flag
  // a <Symbol> full of <Path>s paints ONCE at the defs block's own position --
  // not "nothing", which is what an unregistered component looks like, but a
  // stray mark in the wrong place. Measured 2026-08-28 with
  // fixtures/p9-usesym: the symbol's green path painted at its own coordinates
  // while the <Use> site stayed background. That reads as a CSS/layout bug and
  // is not one, which is exactly the expensive kind.
  //
  // Set on <Defs>, <Symbol>, <ClipPath> and <Mask> -- every rnsvg container
  // that defines rather than draws. Marking one of these that DOES paint would
  // make art vanish, so the list is deliberately short and explicit.
  bool isSvgDefinition{false};

  // <Symbol>: its own viewBox, needed to scale the instance at each <Use>.
  // minX, minY, vbWidth, vbHeight.
  float svgSymbolViewBox[4]{0, 0, 0, 0};
  // <Symbol id> / any element's `name` -- the key a <Use href="#id"> resolves
  // against. Kept separate from svgGradientName because a symbol and a gradient
  // can share neither storage nor lifetime rules.
  std::string svgDefName;

  // <Use>: the href WITHOUT the leading '#', plus the instance box. An empty
  // reference, or one that resolves to nothing, must paint nothing rather than
  // fall through to some default -- a dangling url(#id) is a real authoring
  // state, not an error.
  bool isSvgUse{false};
  std::string svgUseHref;
  float svgUseBox[4]{0, 0, 0, 0};  // x, y, width, height
  bool svgUseHasSize{false};

  // Set on the <LinearGradient>/<RadialGradient> def node itself.
  bool isSvgGradient{false};
  bool svgGradientRadial{false};
  std::string svgGradientName;
  // Flat [offset, argb, offset, argb, ...] exactly as rnsvg packs it.
  std::vector<float> svgGradientStops;
  // Linear: x1,y1,x2,y2. Radial: fx,fy,rx,ry (cx/cy carried in [4],[5]).
  float svgGradientCoords[6]{0, 0, 1, 0, 0, 0};
  int svgGradientUnits{0};  // 0 = objectBoundingBox, 1 = userSpaceOnUse

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

  // Topmost node containing (x, y), or 0 if the point hits nothing.
  //
  // ⛔ ARGUMENTS ARE IN POINTS, NOT DEVICE PIXELS.
  // Same coordinate space as `paint()` receives BEFORE it applies
  // pointScaleFactor as a root transform. A caller holding a GLFW cursor
  // position (device pixels on a retina display) must divide by the same
  // pointScaleFactor first, or every hit on a 2x screen lands at double the
  // intended coordinate and misses low/right targets entirely.
  //
  // "Topmost" is defined by the painter, not by z-order bookkeeping: children
  // paint after their parent and in array order, so the last thing painted at
  // a point is the first thing that should be hit. This walk is `paintNode`'s
  // traversal with the child loop reversed, which is why it needs no extra
  // per-node state and cannot drift out of sync with what is on screen --
  // any future change to paint order is a change to hit order for free.
  facebook::react::Tag hitTest(float x, float y);

  // The retained event emitter for `tag`, or nullptr.
  //
  // Returned BY VALUE (a shared_ptr copy) taken under the same mutex that
  // guards mutation. A reference or raw pointer would be a use-after-free the
  // moment the JS thread applied a transaction that removed the node between
  // lookup and dispatch -- which is exactly the window a press on a view that
  // is unmounting lands in.
  facebook::react::EventEmitter::Shared eventEmitterFor(
      facebook::react::Tag tag);

 private:
  // Returns the hit tag, or 0. `originX/originY` accumulate exactly as in
  // paintNode: frames are PARENT-RELATIVE, so absolute position is the running
  // sum down the tree, never the node's own frame alone.
  facebook::react::Tag hitTestNode(const SceneNode& node,
                                   float originX,
                                   float originY,
                                   float x,
                                   float y);
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
  // Gradient defs by name, rebuilt at the start of every paint. Held as a
  // pointer to the owning node so the stops/coords are never copied.
  std::unordered_map<std::string, const SceneNode*> gradients_;
  // <Symbol>/<Defs>-child definitions by name, rebuilt at the start of every
  // paint for the same reason gradients_ is: a <Use> may precede its target in
  // document order, so it cannot be resolved during the walk.
  std::unordered_map<std::string, const SceneNode*> svgDefs_;
  // Guards against a <Use href> chain that reaches itself. A self-referencing
  // symbol is invalid SVG but perfectly expressible, and the naive recursion
  // is an infinite loop inside the render thread -- a hang, not an error.
  int svgUseDepth_{0};
  // Builds a linear or radial ImpellerColorSource for `def`, resolved against
  // the referencing shape's box (x, y, w, h) for objectBoundingBox units.
  // Caller owns the result and must Release it.
  ImpellerColorSource makeGradientSource(const SceneNode* def, float x, float y,
                                         float w, float h, float alpha) const;
  int painted_{0};  // reset per paint(); incremented in paintNode()
  std::unordered_map<facebook::react::Tag, SceneNode> nodes_;
  std::vector<facebook::react::Tag> roots_;
  ImpellerTypographyContext typography_{nullptr};
};

}  // namespace rni
