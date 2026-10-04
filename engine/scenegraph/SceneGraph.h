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
#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <chrono>
#include <unordered_map>
#include <vector>

#include "impeller.h"
#include "modules/WorldRasterStore.h"
#include "scenegraph/Shadows.h"

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
  // Style audit items 1-4 (scenegraph/Shadows.h). `shadows` holds the iOS
  // shadow* props (as one spec) and every boxShadow entry, in paint order.
  // elevation is Android's material shadow, painted by DrawShadow.
  std::vector<ShadowSpec> shadows;
  float elevation{0.0f};
  float elevationColor[4]{0, 0, 0, 1};
  // parity item 9: RN `pointerEvents` (0 auto, 1 none, 2 box-none,
  // 3 box-only), mirrored from PointerEventsMode. Hit testing honours it.
  int pointerEvents{0};

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
  // ENG-22: the run's TextAttributes::fontFamily, the SAME string
  // ImpellerTextLayoutManager measures with. Empty = Impeller's default face.
  // Painting without it measured the box in one face and drew the glyphs in
  // the fallback, so a mono label overflowed or collided with its neighbour.
  std::string fontFamily;
  // ENG-23: TextAttributes::lineHeight in points (0 = unset). Applied at paint
  // with the SAME setter measure uses (text/LineHeight.h), so the box height
  // and the painted line pitch agree.
  float lineHeight{0.0f};
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
  // item 11: keyboard focus. `focusable` is the View prop (View.js turns
  // tabIndex into it: tabIndex 0 -> true, -1 -> false); TextInput.js always
  // sends it too. `tiEditable` is TextInput's `editable` prop.
  bool focusable{false};
  bool tiEditable{true};
  // The controlled `value`/`defaultValue` prop, captured at mutation time. The
  // LIVE edited string during focus is held by FabricHost and pushed in through
  // setTextInputEdit; this is the fallback the paint uses when the field is not
  // being edited, so an unfocused controlled field still shows its value.
  std::string tiValue;
  std::string tiPlaceholder;
  // ENG-16: multiline + textAlignVertical (react::TextAlignmentVertical:
  // 0 Auto, 1 Top, 2 Bottom, 3 Center). Auto = top for multiline (UITextView)
  // and centre for single-line (UITextField), measured from contentInsets.
  bool tiMultiline{false};
  int tiAlignVertical{0};
  float tiPlaceholderColor[4]{0.6f, 0.6f, 0.6f, 1.0f};
  // item 4a: selection highlight fill. Defaults to rgba(51,144,255,0.35) (a
  // common desktop selection blue) when the field sets no `selectionColor`
  // prop, overwritten at mutation time exactly like tiPlaceholderColor above.
  float tiSelectionColor[4]{0.2f, 0.56470588f, 1.0f, 0.35f};

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

  // <world> ENG-09. `name` keys WorldRasterStore -- the SAME string
  // JS passed to WorldRaster.setPixels(id, ...). Empty means either not a
  // <world> node or a <world> whose `name` prop has not been set yet (the
  // painter then has nothing to look up and paints nothing, matching an
  // unset RNSVGImage `name`/uri: silent, not a crash).
  bool isWorldRaster{false};
  std::string worldRasterName;


  std::vector<facebook::react::Tag> children;
  facebook::react::Tag parent{};
};

class SceneGraph {
 public:
  explicit SceneGraph(ImpellerTypographyContext typography);
  ~SceneGraph();

  // ENG item 2 — SUPERSAMPLE-RNSVG.
  //
  // Impeller gives stroked tessellated paths NO edge-coverage AA (Mac Metal: 2
  // luminance levels, 0% partial). The client-side fix is supersample-then-
  // downsample: render an <Svg> root subtree at N x into an offscreen FBO, then
  // composite it back with a LINEAR filter. The box filter of the downsample
  // synthesises the partial-coverage edge pixels Impeller refuses to emit.
  //
  // ⛔ setRenderContext MUST be called with the SAME ImpellerContext that owns
  // the surface paint() draws into. The offscreen FBO is created in that
  // context's GL sharegroup — the documented requirement for
  // ImpellerTextureCreateWithOpenGLTextureHandleNew. Without it, supersample_
  // is inert (the in-place path runs) rather than crashing: a null context is
  // exactly the "not wired" state, distinct from N=0 "disabled".
  void setRenderContext(ImpellerContext context) { renderContext_ = context; }

  // N. 0 disables (the exact current in-place path, zero behavioural change).
  // >=2 supersamples. 1 is the mutant control: an offscreen round-trip at
  // native resolution, which must NOT anti-alias — the gate proves that.
  void setSupersample(int n) { supersample_ = n; }
  int supersample() const { return supersample_; }

  // ENG item 2b — ROOT SUPERSAMPLE. The device-pixel size of the surface paint()
  // draws into. The whole-tree offscreen is sized N x this, so the root path is
  // inert until a host wires it (headless/windowed both do, next to
  // setRenderContext). Re-set on every window resize so the offscreen tracks the
  // framebuffer; a stale size would supersample into the wrong extent.
  void setSurfaceSize(int pxW, int pxH) { surfacePxW_ = pxW; surfacePxH_ = pxH; }

  // <world> ENG-09. Wires the SAME WorldRasterStore the WorldRaster
  // TurboModule writes into (ReactHost::worldRasterStore()) so paintWorldNode
  // reads what JS actually published. Null (the default) makes every <world>
  // node paint nothing -- the "not wired" state, same shape as
  // renderContext_ being null for supersampling.
  void setWorldRasterStore(std::shared_ptr<WorldRasterStore> store) {
    worldRasterStore_ = std::move(store);
  }
  // ENG-10. Sprite quads the <world> painter actually issued as GPU
  // DrawTextureRect calls during the LAST paint(). Reset per paint(). The gate
  // asserts this equals the drawSprites list length -- proof the quads went
  // through the GPU path, not a silent no-op or a per-sprite node fallback.
  int worldSpritesDrawn() const { return spritesDrawn_; }


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

  // item 7. View commands. Absolute scroll of ScrollView `tag` to (x, y),
  // clamped to its content extent; end=true scrolls to the far end of the
  // overflowing axis (scrollToEnd). Returns tag=0 if `tag` is not a
  // ScrollView.
  ScrollResult scrollTo(facebook::react::Tag tag, float x, float y,
                        bool toEnd);
  // item 7. Sets an UNFOCUSED field's displayed value (setTextAndSelection
  // on a field that is not being edited).
  void setTextInputValue(facebook::react::Tag tag, const std::string& value);

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

  // ── Idle-frame damage signal + wake (P12-01) ──────────────────────────────
  // A monotonic revision, bumped once per applyMutations, per applied direct-
  // prop update (the NativeAnimated path), per text-input edit/focus change,
  // and per scroll that MOVED. The windowed idle-skip loop presents a frame
  // only when this advanced since the last present (or an animation clock is
  // live). Impeller had NO such counter before P12-01: every windowed frame
  // repainted unconditionally, pinning a CPU core on an idle window.
  uint64_t version() const { return version_.load(std::memory_order_acquire); }

  // Bump the revision. Safe from any thread (version_ is atomic) and it also
  // fires the damage wake, so an OFF-thread bump (the JS thread's applyMutations
  // / updateViewProps, or a detached test producer) wakes the GLFW loop if it
  // is asleep in glfwWaitEventsTimeout. Main-thread callers (a windowed scroll,
  // a resize) get a harmless glfwPostEmptyEvent the next poll drains.
  void bumpVersion();

  // Install the wake fired by every version_ bump. The callback only does
  // glfwPostEmptyEvent() (documented thread-safe) so a setState while the loop
  // sleeps in glfwWaitEventsTimeout repaints promptly instead of stalling to
  // the next unrelated input. Null when no loop is listening (headless one-shot
  // gates never install it), so producers pay one null-check. Installed once,
  // before the JS thread starts. Guarded by its OWN mutex (never mutex_) so a
  // bump taken while mutex_ is held — applyMutations does exactly that — cannot
  // invert the lock order against the scene lock.
  void setDamageWake(std::function<void()> wake);

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

  // desktop-input-gap P0 item 1. The first mounted surface root tag, or 0 if
  // nothing has mounted yet. Used as the keyDown/keyUp fallback target when
  // no TextInput (or other view) is focused, so a key event has SOMEWHERE to
  // land rather than being silently swallowed the instant nothing has focus
  // -- the same "nothing focused is a no-op, but the event still exists"
  // shape dispatchKey's TextInput path already draws, just for the case
  // where there is no focus target at all.
  facebook::react::Tag rootTag();

  // item 11. Tab order: every keyboard-focusable node in depth-first tree
  // order (children in paint order), skipping zero-size / display:none
  // subtrees. A TextInput is focusable when editable and its `focusable` prop
  // is true; any other View when its `focusable` prop is true.
  std::vector<facebook::react::Tag> tabOrder();
  bool isTextInputTag(facebook::react::Tag tag);
  // item 11. The View (not TextInput) that has keyboard focus: painted with a
  // focus ring. 0 = none.
  void setFocusedView(facebook::react::Tag tag);
  facebook::react::Tag focusedView();

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
  // item 4a: keyboard text selection. Sets the buffer, caret AND the
  // selection anchor independently -- setTextInputEdit above always
  // COLLAPSES the selection (anchor==caret), which is correct for the click
  // path (item 3; mouse-drag selection is item 4b) and for any edit that
  // leaves no selection behind. A caret move that EXTENDS a selection (Shift
  // held) or a Select-All needs the anchor and caret to differ, which is
  // what this entry point is for. `anchor` and `caret` are both clamped to
  // value.size() defensively, exactly as setTextInputEdit's caret already is.
  void setTextInputSelection(facebook::react::Tag tag,
                             const std::string& value, size_t anchor,
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

  // item 4a: the UTF-8 byte offset of the SELECTION ANCHOR (the end that does
  // NOT move under a Shift+caret-move) for the focused field. Equal to
  // textInputCaretFor's return when the selection is collapsed -- callers
  // needing "is there a selection" compare the two. Returns 0 when `tag` is
  // not the focused field, matching textInputCaretFor's own convention.
  size_t textInputSelectionAnchorFor(facebook::react::Tag tag);

  // desktop-input-gap item 3. Click-to-caret: the UTF-8 BYTE OFFSET of the
  // codepoint boundary nearest (screenX, screenY) inside `tag`'s displayed
  // text (the live edit buffer if focused, else its controlled tiValue).
  // Uses the EXACT SAME prefix-width paragraph measurement paintNode's caret
  // branch already performs to place the painted bar -- see
  // glyphBoundariesFor's header -- so a click and the caret it produces can
  // never disagree about where a boundary sits. (screenX, screenY) are in the
  // SAME coordinate space hitTest/paintNode use (layout points; identical to
  // screen pixels on a 1x host with no --scale override -- see
  // host/PointScale.h). `y` is currently unused (single-line fields only; a
  // future multiline field would use it to pick the line first).
  //
  // Returns 0 when `tag` is not a text field, has no typography context, or
  // its displayed text is empty -- 0 is the only sensible caret for an empty
  // field, matching setTextInputFocus's own seed for that case.
  size_t caretIndexForClick(facebook::react::Tag tag, float screenX,
                            float screenY);

  // desktop-input-gap item 3 debug/gate hook. One
  // `rn-impeller: ti_glyph_x tag=<t> xs=<x0>,<x1>,...` line giving the SCREEN
  // x (see caretIndexForClick's coordinate-space note) of EVERY codepoint
  // boundary in `tag`'s displayed text -- so a gate can aim a REAL XTest
  // click at the midpoint between two boundaries instead of guessing font
  // metrics. Empty string if `tag` is not a text field with displayed text.
  std::string glyphBoundaryReportFor(facebook::react::Tag tag);
  // One `paragraph_text tag=<t> "<text>"` line per Paragraph node, for the
  // ENG-01b edit gate: the fixture's controlled label renders `len=N v=...`, so
  // this exposes the JS re-render result to a headless assertion.
  std::string paragraphTextReport();

 private:
  // item 3. Codepoint-boundary byte offsets of `tag`'s displayed text and the
  // SCREEN x (layout points) of each, measured with the SAME prefix-width
  // paragraph build paintNode uses for the caret. Caller holds mutex_.
  // Returns false when `tag` is not a text field or typography is missing.
  bool glyphBoundariesLocked(facebook::react::Tag tag,
                             std::vector<size_t>* offsets,
                             std::vector<float>* xs);
  // item 3. Absolute origin of `tag`, walked exactly as hitTestNode does
  // (sum of frame origins, minus each ScrollView ancestor's scroll offset).
  // Caller holds mutex_.
  bool absoluteOriginLocked(facebook::react::Tag tag, float* ox, float* oy);
  // Returns the hit tag, or 0. `originX/originY` accumulate exactly as in
  // paintNode: frames are PARENT-RELATIVE, so absolute position is the running
  // sum down the tree, never the node's own frame alone.
  void tabOrderWalk(const SceneNode& node,
                    std::vector<facebook::react::Tag>* out);
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
  // ENG item 2. Renders the <Svg> root subtree rooted at `node` into an
  // N x offscreen FBO and composites it back into `builder` with a LINEAR
  // downsample, at painted position (x,y,w,h). Returns true if it handled the
  // subtree (the caller then SKIPS the in-place walk); false if it could not
  // (no GL context, degenerate size, N<2, or a GL failure) so the caller falls
  // back to painting in place. The fallback is why a supersample failure
  // degrades to a correct-but-aliased icon rather than a blank one.
  bool paintSvgRootSupersampled(ImpellerDisplayListBuilder builder,
                                const SceneNode& node, float x, float y,
                                float w, float h);
  // Counts the ++painted_ increments a paintNode() walk of this subtree would
  // make, without painting. Mirrors paintNode traversal (self, definition early
  // return, children, <Use> expansion bounded by kMaxUseDepth). The supersample
  // hook uses it so painted_nodes is cache-independent.
  int countPaintedNodes(const SceneNode& node, int useDepth);
  // ENG item 2b — ROOT SUPERSAMPLE. Renders the ENTIRE tree (all roots) into a
  // single N x offscreen the size of the surface, downsamples with the same
  // iterative-halve box filter paintSvgRootSupersampled uses, and composites the
  // near-native result back into `builder` in DEVICE PIXELS. This is the fallback
  // (option b) for AA on primitives Impeller does not edge-antialias itself — a
  // View's stroked rounded border, whose corner arc is otherwise a binary step.
  // Returns true if it handled the frame (paint() then skips the in-place walk);
  // false if it could not (no context, N<2, zero/oversize surface, GL failure)
  // so paint() falls back to the exact in-place walk — a supersample failure
  // degrades to a correct-but-aliased frame, never a blank one. pointScaleFactor
  // is the same device scale paint() would otherwise apply at the root.
  bool paintTreeSupersampled(ImpellerDisplayListBuilder builder,
                             float pointScaleFactor);
  // Renders the <Svg> subtree rooted at `node` (painted at x,y,w,h) into a
  // fresh pxW x pxH offscreen FBO and returns the adopted ImpellerTexture
  // (ownership transferred from the GL handle — caller Releases it), or null on
  // any GL/Impeller failure. Depth+stencil attached so concave fills work.
  ImpellerTexture renderSvgSubtreeToTexture(const SceneNode& node, float x,
                                            float y, float w, float h, int pxW,
                                            int pxH);
  // Downsamples `src` (size srcW x srcH) into a fresh dstW x dstH texture via a
  // single LINEAR DrawTextureRect — an EXACT box average only when it is a 2x
  // reduction, which is why paintSvgRootSupersampled halves iteratively rather
  // than reducing N x in one step. Returns the adopted texture (caller
  // Releases) or null. Does NOT release `src`.
  ImpellerTexture halveTexture(ImpellerTexture src, int srcW, int srcH,
                               int dstW, int dstH);
  // <world> ENG-09. Reads WorldRasterStore by node.worldRasterName and paints
  // the RGBA buffer into (x,y,w,h) as a textured rect. Returns false (paints
  // nothing) when the store is unwired, the name is empty, or nothing has
  // ever been set for it -- all silent-no-op, never a crash, matching the
  // "unset image source" convention the rest of this file uses.
  bool paintWorldNode(ImpellerDisplayListBuilder builder, const SceneNode& node,
                      float x, float y, float w, float h);
  // <world> ENG-10. Paints the store's drawSprites list for node.worldRasterName
  // OVER the world buffer, back-to-front, one DrawTextureRect per sprite from
  // the textureId-keyed atlas cache. Returns false when there is no list.
  bool paintWorldSprites(ImpellerDisplayListBuilder builder,
                         const SceneNode& node, float x, float y, float w,
                         float h);
  // <world> ENG-21. Nearest when JS set WorldRaster.setSampling(name,
  // 'nearest'), else linear. Shared by terrain and sprites.
  ImpellerTextureSampling worldSampling(const SceneNode& node) const;
  // Content key for the per-icon texture cache: every input that changes the
  // rasterised pixels. Two icons with the same key reuse one ImpellerTexture.
  std::string svgSubtreeCacheKey(const SceneNode& node, int pxW, int pxH) const;
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
  // The paint's point->pixel scale, for DrawShadow's device_pixel_ratio
  // (style audit item 4, elevation). Set at the top of paint().
  float pointScale_{1.0f};

  // ENG item 2 — supersample state.
  // renderContext_ is the ImpellerContext whose GL sharegroup the offscreen FBO
  // is created in. Null until setRenderContext() wires it, which keeps
  // supersample inert on hosts (Windows, Android) that do not call it.
  ImpellerContext renderContext_{nullptr};
  int supersample_{0};  // 0 disabled, 1 mutant control, >=2 real supersample
  // ENG item 2b — ROOT SUPERSAMPLE surface size, device pixels. 0 until a host
  // calls setSurfaceSize(); paintTreeSupersampled refuses to run at 0 rather
  // than guess, so the root path is inert on any host that does not wire it.
  int surfacePxW_{0};
  int surfacePxH_{0};
  // ENG item 2b — the whole-tree offscreen texture from the previous frame.
  // paintTreeSupersampled composites this into `builder`, but the display list
  // the host draws is not consumed until after paint() returns, so the texture
  // must OUTLIVE this call. Held here and released at the START of the next root
  // supersample (double-buffered), and in the destructor — releasing it
  // immediately after DrawTextureRect would free a texture the pending display
  // list still references (a use-after-free that the icon path sidesteps only
  // because its cache keeps every texture alive across frames).
  ImpellerTexture treeTexture_{nullptr};
  // Per-icon texture cache. Keyed by content (paths+colours+px size+N) so the
  // same icon rendered on many rows rasterises ONCE. Holds the ImpellerTexture
  // (ownership already transferred to Impeller from the adopted GL handle), NOT
  // a raw GL handle — re-adopting a handle twice double-frees it. Bounded LRU:
  // svgCacheOrder_ is MRU-back; the front is evicted past kSvgCacheMax so a
  // scrolling icon list cannot leak GPU textures.
  struct SvgCacheEntry {
    ImpellerTexture texture{nullptr};
    int texW{0};
    int texH{0};
  };
  static constexpr size_t kSvgCacheMax = 256;
  std::unordered_map<std::string, SvgCacheEntry> svgCache_;
  std::vector<std::string> svgCacheOrder_;  // LRU: front = oldest
  // <world> ENG-09. The store paintWorldNode reads by node name; wired by
  // setWorldRasterStore(), null until a host calls it.
  std::shared_ptr<WorldRasterStore> worldRasterStore_;
  // Per-node-tag GL texture cache for <world>, keyed by react::Tag (each
  // <world> instance owns exactly one texture -- unlike svgCache_, there is no
  // content-sharing across different <world> nodes with the same name, since
  // each may be at a different size/frame). Re-uploaded (glTexSubImage2D) when
  // the store's version for that node's name advances past what was last
  // uploaded; fully reallocated (glTexImage2D) on the first frame or a
  // width/height change.
  struct WorldTextureEntry {
    ImpellerTexture texture{nullptr};
    // GL texture handle -- stored as uint32_t (GLuint's real underlying type
    // on every platform this engine targets) so this header does not need to
    // pull in a GL headers just to declare the cache; GLES3/gl3.h is only
    // ever included from the .cpp, and only on the two platforms
    // RNI_SUPERSAMPLE_GL covers.
    uint32_t glTex{0};
    int texW{0};
    int texH{0};
    uint64_t uploadedVersion{0};
  };
  std::unordered_map<facebook::react::Tag, WorldTextureEntry> worldTextureCache_;
  // <world> ENG-10. Sprite-atlas GPU textures keyed by textureId (NOT by node
  // tag -- one peep texture is shared by every sprite and every <world> that
  // references it). Uploaded once per registerSprite version; drawSprites
  // frames only re-reference. Released in the destructor.
  std::unordered_map<std::string, WorldTextureEntry> spriteTextureCache_;
  int spritesDrawn_{0};  // reset per paint(); see worldSpritesDrawn()
  // ENG-06. Count of PROPS applied by updateViewProps(), not calls made.
  unsigned long directPropUpdates_{0};
  // P12-01: idle-frame damage revision, bumped by bumpVersion(). Atomic so an
  // off-thread producer (JS applyMutations / updateViewProps) can bump it while
  // the GLFW loop reads it on the main thread with no scene lock held.
  std::atomic<uint64_t> version_{0};
  // P12-01: the wake fired by bumpVersion(). Guarded by its OWN mutex (never
  // mutex_) so applyMutations — which bumps while holding mutex_ — cannot invert
  // the lock order. Null until a windowed idle-skip loop installs it.
  mutable std::mutex wakeMutex_;
  std::function<void()> damageWake_;
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
  // item 4a: the UTF-8 byte offset of the selection's FIXED end (the end
  // Shift+move does not touch). Equal to tiCaret_ when the selection is
  // collapsed -- "is there a selection" is `tiSelAnchor_ != tiCaret_`, never
  // a separate bool, so the two can never disagree about the collapsed case.
  size_t tiSelAnchor_{0};
  // item 11: focused non-TextInput View (focus ring). 0 = none.
  facebook::react::Tag focusedView_{0};
  // <TextInput>. ENG-01b item 5: caret blink. The steady_clock instant the
  // caret was last RESET to visible -- set on focus, on a click into the field,
  // and on EVERY keystroke. paintNode blinks the caret from the time elapsed
  // since this (see CaretBlink.h): visible for the first half-period after a
  // reset, so a burst of typing can never leave the insertion point behind an
  // off phase. steady_clock, not system_clock: the blink must not jump when the
  // wall clock is stepped (NTP, DST), and it is a duration, not a date.
  std::chrono::steady_clock::time_point tiCaretResetAt_{
      std::chrono::steady_clock::now()};
};

}  // namespace rni
