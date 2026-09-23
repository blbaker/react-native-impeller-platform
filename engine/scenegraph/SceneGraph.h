// SceneGraph — the retained render tree. Fabric hands us flat mutation lists;
// this keeps a tag-keyed node tree and paints it into an ImpellerDisplayList.
//
// Threading: mutations arrive on the JS thread, paint happens on whoever owns
// the surface. One mutex guards the tree, so a paint mid-commit sees a
// consistent tree rather than a half-applied transaction.
#pragma once

#include <react/renderer/components/scrollview/ScrollViewProps.h>
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

  // ENG-09 hover/cursor. The RN `cursor` ViewProp, collapsed to the three
  // shapes this host has standard GLFW cursors for. NOT a bool "is hoverable":
  // there is no such signal in Fabric -- every <View> mounts a
  // TouchEventEmitter whether or not JS wired onPress, and the emitter's
  // enabled flag is private -- so the honest, RN-native source for "what
  // cursor belongs over this view" is ViewProps.cursor, which is exactly what
  // web/RN authors set (Pressable does NOT set it by default; an app that
  // wants a hand writes cursor:'pointer'). 0 arrow, 1 hand (Cursor::Pointer),
  // 2 ibeam (Cursor::Text). Defaulted to arrow so an un-annotated view reads
  // as arrow, matching every existing app that never set the prop.
  int cursorKind{0};

  // <ScrollView>. ENG-02.
  //
  // ⛔ THE OFFSET IS THE HOST'S STATE, NOT THE SHADOW TREE'S.
  // On a real platform the scroll position lives in the native scroll view and
  // is REPORTED to React; RN's ScrollViewShadowNode carries a contentOffset for
  // restoration, not as the frame-to-frame source of truth. This engine IS the
  // platform, so the offset is owned here and survives mutation transactions --
  // reading it back off props every commit would snap the list to the top on
  // any unrelated re-render, which reads as "scrolling doesn't stick".
  bool isScrollView{false};
  float scrollY{0.0f};
  // ENG-02b horizontal. The X offset is owned here for the SAME reason scrollY
  // is (see the header note above the struct): the offset is the host's state,
  // not the shadow tree's, and must survive mutation transactions.
  float scrollX{0.0f};
  // ScrollViewProps::horizontal, captured only as the AXIS FALLBACK. It is NOT
  // the axis source: off Android RN never swaps in AndroidHorizontalScrollView,
  // so `<ScrollView horizontal>` arrives with horizontal==false and axis-locking
  // on it would make the strip un-scrollable. The axis is derived from which way
  // the content overflows (scrollBy); this prop is consulted only when neither
  // or both axes overflow.
  bool scrollHorizontal{false};
  // Content height as last laid out (the single child's frame height). Cached
  // at paint/mutation time so clamping does not have to walk the tree from the
  // event thread.
  float scrollContentHeight{0.0f};

  // Text (Paragraph nodes). Laid out at mount time from ParagraphState so the
  // painted text is the same object that was measured.
  bool isParagraph{false};
  std::string text;
  float fontSize{14};
  float textColor[4]{0, 0, 0, 1};
  // numberOfLines. Must be applied at PAINT time as well as measure time, or a
  // clamped label measures one line and paints three.
  int maxLines{0};
  // ellipsizeMode. RN default is Tail. Only meaningful together with maxLines >
  // 0 (an unclamped paragraph never truncates), and applied at PAINT time via
  // ImpellerParagraphStyleSetEllipsis so a clamped line ends in "…" rather than
  // a hard cut. Clip means "no ellipsis string", which is a nullptr to Impeller.
  int ellipsizeMode{0};  // matches react::EllipsizeMode: 0 Clip,1 Head,2 Tail,3 Middle
  // textTransform. Applied to node.text at MUTATION time (not paint) so the
  // measured string and the painted string are the same object — measuring the
  // raw case and painting the transformed case would disagree on width.
  int textTransform{0};  // react::TextTransform: 0 None,1 Upper,2 Lower,3 Capitalize,4 Unset

  // <TextInput>. ENG-01b. A TextInput is NOT a Paragraph: it paints a single
  // editable line from a native-held buffer, a placeholder when that buffer is
  // empty, and a caret when focused. isParagraph stays false so the Paragraph
  // paint path (which reads ParagraphState, a state a TextInput does not carry)
  // is never entered for it.
  bool isTextInput{false};
  // The controlled `value`/`defaultValue` prop, captured at mutation time. The
  // LIVE edited string during focus is held by FabricHost and pushed in through
  // setTextInputEdit; this is the fallback the paint uses when the field is not
  // being edited, so an unfocused controlled field still shows its value.
  std::string tiValue;
  std::string tiPlaceholder;
  float tiPlaceholderColor[4]{0.6f, 0.6f, 0.6f, 1.0f};

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
  // ⛔ THE ROOT <Svg>'s OWN viewBox. ENG-05a.
  //
  // NOT the same storage as svgSymbolViewBox, and deliberately so. A <Symbol>'s
  // viewBox is consumed at each <Use> SITE (SceneGraph.cpp, the isSvgUse
  // branch) because one symbol scales differently per instance. The root's is
  // consumed by the root itself, once, around its own child walk. Sharing one
  // array would make a <Symbol> nested inside an <Svg> overwrite its parent's
  // mapping -- and the symptom would be "the icon is subtly the wrong size",
  // which reads as a design tweak rather than a bug.
  //
  // Before this existed the root viewBox was PARSED by codegen
  // (RNSVGSvgViewProps::minX/minY/vbWidth/vbHeight in
  // engine/svg/generated/.../Props.h) and then dropped on the floor: the props
  // reader had no RNSVGSvgView branch at all, so every path painted in raw user
  // units. A 16x16 <Svg viewBox="0 0 24 24"> declared a 16x16 Yoga box and
  // painted 24 units of art into it, overflowing 8pt.
  bool isSvgRoot{false};
  bool svgRootHasViewBox{false};
  float svgRootViewBox[4]{0, 0, 0, 0};  // minX, minY, vbWidth, vbHeight
  // preserveAspectRatio, split as rnsvg ships it: `align` is the alignment
  // token ("xMidYMid", "none", ...) and `meetOrSlice` is 0=meet, 1=slice.
  // An EMPTY align means the prop was never set, which SVG defines as
  // "xMidYMid meet" -- NOT as "none". Treating unset as none is the specific
  // mistake that makes every square icon look correct and every non-square one
  // stretch.
  std::string svgRootAlign;
  int svgRootMeetOrSlice{0};


  std::vector<facebook::react::Tag> children;
  facebook::react::Tag parent{};
};

class SceneGraph {
 public:
  explicit SceneGraph(ImpellerTypographyContext typography);

  // Applies one MountingTransaction's mutations, in order.
  struct ScrollResult {
    facebook::react::Tag tag{0};
    float offsetX{0.0f};
    float offsetY{0.0f};
    float contentWidth{0.0f};
    float contentHeight{0.0f};
    float containerWidth{0.0f};
    float containerHeight{0.0f};
    bool moved{false};
  };

  // Finds the topmost ScrollView under (x, y) in POINTS -- same space as
  // hitTest -- and adds `dy` points to its offset, clamped to
  // [0, contentHeight - containerHeight].
  //
  // ⛔ CLAMPED HERE, NOT IN THE CALLER. The host does not know the content
  // height, and an unclamped offset scrolls a 6-row list into empty space
  // forever while still emitting perfectly plausible onScroll events -- the
  // failure looks like "the list is blank" long after the wheel stopped.
  facebook::react::Tag scrollViewAt(float x, float y);
  ScrollResult scrollBy(float x, float y, float dx, float dy);

  void applyMutations(const facebook::react::ShadowViewMutation::List& mutations,
                      bool log = false);

  // ⛔ ENG-06: THE SECOND WAY PROPS ARRIVE, AND THE ONE ANIMATION USES.
  //
  // Mounting transactions are not the only prop path. RN's C++ NativeAnimated
  // engine deliberately BYPASSES the shadow tree for the properties it drives
  // every frame -- it calls UIManager::synchronouslyUpdateViewOnUIThread(tag,
  // props) with a folly::dynamic of just the changed keys, precisely so a
  // 60fps opacity ramp does not commit a shadow-tree revision per frame.
  //
  // That lands on SchedulerDelegate::schedulerShouldSynchronouslyUpdateView-
  // OnUIThread. While that override was an empty stub, an animation looked
  // EXACTLY like a working one from every angle we had: the module registered,
  // the pump ticked 1:1 with --frames, the node graph evaluated, props were
  // computed -- and then dropped on the floor. Nothing errored, nothing logged,
  // and the only observable was that the pixels never moved.
  //
  // Returns true if `tag` was found. The caller distinguishes "applied" from
  // "no such node", because an update for an unmounted tag is a real and
  // different defect from an update that was ignored.
  bool updateViewProps(facebook::react::Tag tag, const folly::dynamic& props);

  // How many props updateViewProps() actually APPLIED (not how many calls it
  // received). A gate needs this: a call that finds the node and then matches
  // no known key is indistinguishable, from the outside, from no call at all.
  unsigned long directPropUpdates() const { return directPropUpdates_; }

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

  // ENG-09 hover/cursor. The cursor shape for `tag`: 0 arrow, 1 hand, 2 ibeam.
  // Returns 0 (arrow) for an unknown tag, so a hover that resolves nothing
  // reads as arrow -- the same answer as hovering empty space. Taken under the
  // same mutex as eventEmitterFor for the same reason: the JS thread may be
  // removing the node between the hit test and this read.
  int cursorKindFor(facebook::react::Tag tag);

  // <TextInput>. ENG-01b. The editing state the PAINT reads: which field has
  // focus, the live edited string, and the caret index within it. FabricHost
  // owns the editing logic (keystroke -> buffer -> event); these setters are the
  // one channel by which that logic reaches the painter, so the caret and the
  // glyphs on screen cannot disagree with the buffer JS is being told about.
  // Held here, not in the node, because focus is a singleton (one field at a
  // time) and lives across the mounting transactions that rebuild the nodes.
  void setTextInputFocus(facebook::react::Tag tag);
  void setTextInputEdit(facebook::react::Tag tag, const std::string& value,
                        size_t caret);
  void clearTextInputFocus();
  facebook::react::Tag focusedTextInput();
  // The value a field should display: the live edit buffer if it is focused,
  // else its controlled tiValue prop. Used by the paint and returned to
  // FabricHost so a click that focuses an already-populated field seeds its
  // edit buffer from the value already on screen.
  std::string textInputValueFor(facebook::react::Tag tag);
  // The caret index within the focused field's edit buffer. Returns 0 when the
  // tag is not the focused field (an unfocused field paints no caret). Exposed
  // so a gate can assert the caret ADVANCED with the typed characters, not just
  // that the buffer changed -- a buffer that grows while the caret stays at 0
  // is a real editing bug the value-only check cannot see.
  size_t textInputCaretFor(facebook::react::Tag tag);
  // One `paragraph_text tag=<t> "<text>"` line per Paragraph node, for the
  // ENG-01b edit gate: the fixture's controlled label renders `len=N v=...`, so
  // this exposes the JS re-render result to a headless assertion.
  std::string paragraphTextReport();

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
  // ENG-06. Count of PROPS applied by updateViewProps(), not calls made.
  unsigned long directPropUpdates_{0};
  std::unordered_map<facebook::react::Tag, SceneNode> nodes_;
  std::vector<facebook::react::Tag> roots_;
  ImpellerTypographyContext typography_{nullptr};
  // <TextInput>. ENG-01b. Focus is a singleton: at most one field edits at a
  // time. tiFocused_==0 means no field is focused (caret not painted anywhere).
  // tiEditValue_ is the live buffer the keystroke loop mutates; tiCaret_ is the
  // insertion index within it (0..len). All three are read by paintNode under
  // mutex_, written by FabricHost's setters under the same lock.
  facebook::react::Tag tiFocused_{0};
  std::string tiEditValue_;
  size_t tiCaret_{0};
};

}  // namespace rni
