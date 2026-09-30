#include "fabric/FabricHost.h"

#include <react/renderer/componentregistry/ComponentDescriptorProviderRegistry.h>
#include <react/renderer/components/iostextinput/TextInputComponentDescriptor.h>
#include <react/renderer/components/iostextinput/TextInputShadowNode.h>
#include <react/renderer/components/textinput/TextInputEventEmitter.h>
#include <react/renderer/components/root/RootComponentDescriptor.h>
#include <react/renderer/components/scrollview/ScrollViewComponentDescriptor.h>
#include <react/renderer/components/scrollview/ScrollViewEventEmitter.h>
#include <react/renderer/components/text/ParagraphComponentDescriptor.h>
#include <react/renderer/components/text/RawTextComponentDescriptor.h>
#include <react/renderer/components/text/TextComponentDescriptor.h>
#include <react/renderer/components/view/ViewComponentDescriptor.h>
#include <react/renderer/core/EventBeat.h>
#include <react/renderer/core/LayoutConstraints.h>
#include <react/renderer/core/LayoutContext.h>
#include <react/renderer/mounting/MountingCoordinator.h>
#include <react/renderer/mounting/MountingTransaction.h>
#include <react/renderer/runtimescheduler/RuntimeScheduler.h>
#include <react/renderer/scheduler/Scheduler.h>
#include <react/renderer/scheduler/SchedulerDelegate.h>
#include <react/renderer/scheduler/SchedulerToolbox.h>
#include <react/renderer/scheduler/SurfaceHandler.h>
#include <react/renderer/components/view/TouchEventEmitter.h>

#include <chrono>
#include <react/runtime/ReactInstance.h>
#include <react/utils/ContextContainer.h>

#if RNI_WITH_RNSVG
// Two ComponentDescriptor headers: the vendor's own (Group/Path/... — hand-
// written `using` aliases in common/cpp/) and ours (SvgView — codegen output,
// since react-native-svg's Svg.js resolves to the platform-suffixed
// RNSVGSvgView/RNSVGSvgViewAndroid names that only the codegen emits).
// See engine/cmake/RnSvg.cmake's header comment on the vendor-owns-contract
// / we-own-pixels split.
#include "RNSVGComponentDescriptors.h"
#include <react/renderer/components/rnsvg/ComponentDescriptors.h>
#endif

#include <atomic>
#include <cstdio>

#include "modules/CoreModules.h"
#include "scenegraph/SceneGraph.h"
#include "text/ImpellerTextLayoutManager.h"

namespace rni {

namespace react = facebook::react;

namespace {

class ImpellerSchedulerDelegate : public react::SchedulerDelegate {
 public:
  ImpellerSchedulerDelegate(SceneGraph* sceneGraph, bool logMutations)
      : sceneGraph_(sceneGraph), logMutations_(logMutations) {}

  void schedulerDidFinishTransaction(
      const std::shared_ptr<const react::MountingCoordinator>&) override {
    // Android-only observation hook; we pull in ShouldRender below.
  }

  void schedulerShouldRenderTransactions(
      const std::shared_ptr<const react::MountingCoordinator>&
          mountingCoordinator) override {
    // ⛔ EXACTLY ONE PULL PER RENDER STEP. Do not turn this into a
    // `while (auto t = pullTransaction())` drain loop: once a
    // MountingOverrideDelegate is registered (RN's LayoutAnimation KFM), the
    // override branch manufactures a fresh transaction on every call while
    // shouldOverridePullTransaction() is true, so the loop never terminates
    // and the JS thread never returns to its event loop. RN's own consumer
    // pulls exactly once.
    if (auto transaction = mountingCoordinator->pullTransaction()) {
      if (sceneGraph_ != nullptr) {
        sceneGraph_->applyMutations(transaction->getMutations(), logMutations_);
      }
    }
  }

  void schedulerShouldMergeReactRevision(react::SurfaceId) override {}
  void schedulerDidRequestPreliminaryViewAllocation(
      const react::ShadowNode&) override {}
  void schedulerDidDispatchCommand(const react::ShadowView&, const std::string&,
                                   const folly::dynamic&) override {}
  void schedulerDidSendAccessibilityEvent(const react::ShadowView&,
                                          const std::string&) override {}
  void schedulerDidSetIsJSResponder(const react::ShadowView&, bool,
                                    bool) override {}
  // ⛔ ENG-06: THIS IS THE ANIMATION PROP PATH. IT WAS AN EMPTY STUB.
  //
  // RN's C++ NativeAnimated engine does NOT drive per-frame props through a
  // mounting transaction -- committing a shadow-tree revision 60 times a second
  // is exactly what it exists to avoid. It calls
  // UIManager::synchronouslyUpdateViewOnUIThread(tag, partialProps), which
  // arrives here and nowhere else.
  //
  // While this override did nothing, an animation was indistinguishable from a
  // working one on every instrument we had: NativeAnimatedModule registered
  // with all 25 methods, the frame pump ticked exactly 1:1 with --frames, the
  // animated node graph evaluated, opacity was computed per frame -- and then
  // dropped here. No error, no log line, no GL warning. The only observable was
  // that the pixels never moved, which reads as "the animation did not run".
  //
  // An empty override is a worse failure than a missing one: the compiler is
  // satisfied, the interface looks implemented, and the silence is total.
  void schedulerShouldSynchronouslyUpdateViewOnUIThread(
      react::Tag tag, const folly::dynamic& props) override {
    if (sceneGraph_ == nullptr) {
      return;
    }
    if (!sceneGraph_->updateViewProps(tag, props) && logMutations_) {
      // Not a failure of this path: an update can legitimately race a REMOVE.
      // Logged only under --log-mutations so it cannot be mistaken for normal
      // output, but never silently swallowed.
      std::printf("[fabric] SYNC-UPDATE for unmounted tag=%d\n", tag);
    }
  }
  void schedulerDidUpdateShadowTree(
      const std::unordered_map<react::Tag, folly::dynamic>&) override {}
  void schedulerDidCaptureViewSnapshot(react::Tag, react::SurfaceId) override {}
  void schedulerDidSetViewSnapshot(react::Tag, react::Tag,
                                   react::SurfaceId) override {}
  void schedulerDidClearPendingSnapshots() override {}

 private:
  SceneGraph* sceneGraph_;
  bool logMutations_;
};

// ⛔ The base EventBeat is INERT: request() only sets a flag, and the PLATFORM
// is expected to call induce() before its run loop sleeps (iOS run-loop
// observer / Android Choreographer). Without a beat that actually induces,
// events dispatched through EventDispatcher queue forever and JS never sees
// one — with no error anywhere.
class ImpellerEventBeat : public react::EventBeat {
 public:
  ImpellerEventBeat(std::shared_ptr<OwnerBox> ownerBox,
                    react::RuntimeScheduler& runtimeScheduler)
      : EventBeat(std::move(ownerBox), runtimeScheduler),
        runtimeScheduler_(runtimeScheduler) {}

  void request() const override {
    EventBeat::request();
    bool expected = false;
    if (isInduceScheduled_.compare_exchange_strong(expected, true)) {
      runtimeScheduler_.scheduleWork(
          [this, ownerBox = ownerBox_](facebook::jsi::Runtime&) {
            auto owner = ownerBox->owner.lock();
            if (!owner) return;
            isInduceScheduled_ = false;
            induce();
          });
    }
  }

 private:
  react::RuntimeScheduler& runtimeScheduler_;
  mutable std::atomic<bool> isInduceScheduled_{false};
};

// desktop-input-gap item 2a. Caret + UTF-8 helpers.
//
// ⛔ EVERY CALLER LANDS THE CARET ONLY THROUGH THESE FUNCTIONS, NEVER A BARE
// +/-1. The edit buffer is UTF-8 (variable-width); a caret held as a byte
// offset that is not on a codepoint boundary would split a multi-byte
// sequence the next time it is used to substr/insert/erase, corrupting the
// buffer into invalid UTF-8 (exactly M3 in the mutation suite).

// True if `c` is a UTF-8 continuation byte (10xxxxxx).
bool IsUtf8Continuation(unsigned char c) { return (c & 0xC0) == 0x80; }

// The byte offset of the codepoint boundary immediately BEFORE `pos` (`pos`
// must itself be a boundary; 0 returns 0). MoveLeft/Backspace.
size_t Utf8PrevBoundary(const std::string& s, size_t pos) {
  if (pos == 0) return 0;
  size_t i = pos - 1;
  while (i > 0 && IsUtf8Continuation((unsigned char)s[i])) --i;
  return i;
}

// The byte offset of the codepoint boundary immediately AFTER `pos` (`pos`
// must itself be a boundary; s.size() returns s.size()). MoveRight/
// DeleteForward.
size_t Utf8NextBoundary(const std::string& s, size_t pos) {
  if (pos >= s.size()) return s.size();
  size_t i = pos + 1;
  while (i < s.size() && IsUtf8Continuation((unsigned char)s[i])) ++i;
  return i;
}

// Encodes one Unicode scalar value as UTF-8 and appends it to `out`, or
// returns false and leaves `out` untouched. Rejects control bytes (< 0x20,
// == 0x7F -- a control byte here would corrupt the buffer and paint a tofu
// box, same reasoning the old ASCII-only filter had), UTF-16 surrogate
// halves (0xD800-0xDFFF: not valid Unicode SCALAR values, only valid as one
// half of a UTF-16 pair -- a caller decoding a JS string one UTF-16 unit at
// a time must never forward a lone surrogate here), and anything past the
// Unicode range. Every other codepoint >= 0x20 is accepted, unlike the old
// InsertChar which silently dropped everything outside 0x20..0x7E.
bool Utf8EncodeAppend(std::string* out, unsigned int cp) {
  if (cp < 0x20 || cp == 0x7F) return false;
  if (cp >= 0xD800 && cp <= 0xDFFF) return false;
  if (cp > 0x10FFFF) return false;
  if (cp <= 0x7F) {
    out->push_back((char)cp);
  } else if (cp <= 0x7FF) {
    out->push_back((char)(0xC0 | (cp >> 6)));
    out->push_back((char)(0x80 | (cp & 0x3F)));
  } else if (cp <= 0xFFFF) {
    out->push_back((char)(0xE0 | (cp >> 12)));
    out->push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
    out->push_back((char)(0x80 | (cp & 0x3F)));
  } else {
    out->push_back((char)(0xF0 | (cp >> 18)));
    out->push_back((char)(0x80 | ((cp >> 12) & 0x3F)));
    out->push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
    out->push_back((char)(0x80 | (cp & 0x3F)));
  }
  return true;
}

// Decodes the codepoint starting at byte offset `i` (must be a boundary),
// for the word-move scan below, which needs to classify codepoints as
// whitespace without splitting a multi-byte sequence. A malformed/truncated
// sequence decodes as U+FFFD and advances by one byte, so a bad byte can
// never hang the scan.
unsigned int Utf8DecodeAt(const std::string& s, size_t i, size_t* outLen) {
  unsigned char c0 = (unsigned char)s[i];
  if (c0 < 0x80) {
    *outLen = 1;
    return c0;
  }
  size_t len = (c0 & 0xE0) == 0xC0   ? 2
             : (c0 & 0xF0) == 0xE0   ? 3
             : (c0 & 0xF8) == 0xF0   ? 4
                                     : 0;
  if (len == 0 || i + len > s.size()) {
    *outLen = 1;
    return 0xFFFD;
  }
  unsigned int cp = c0 & (0xFFu >> (len + 1));
  for (size_t k = 1; k < len; ++k) {
    unsigned char c = (unsigned char)s[i + k];
    if (!IsUtf8Continuation(c)) {
      *outLen = 1;
      return 0xFFFD;
    }
    cp = (cp << 6) | (c & 0x3F);
  }
  *outLen = len;
  return cp;
}

bool IsWordBreakSpace(unsigned int cp) { return cp == ' ' || cp == '\t'; }

// Word-left: skip whitespace immediately before the caret, then skip the
// word itself, landing at its start. Word-right: skip the word under/after
// the caret, then skip trailing whitespace, landing at the start of the
// NEXT word (or end of buffer). Deliberately simple (ASCII whitespace only)
// -- item 2a asks for caret movement, not full Unicode word-segmentation
// (UAX #29).
size_t Utf8WordLeft(const std::string& s, size_t pos) {
  size_t i = pos;
  while (i > 0) {
    size_t prev = Utf8PrevBoundary(s, i);
    size_t len;
    unsigned int cp = Utf8DecodeAt(s, prev, &len);
    if (!IsWordBreakSpace(cp)) break;
    i = prev;
  }
  while (i > 0) {
    size_t prev = Utf8PrevBoundary(s, i);
    size_t len;
    unsigned int cp = Utf8DecodeAt(s, prev, &len);
    if (IsWordBreakSpace(cp)) break;
    i = prev;
  }
  return i;
}

size_t Utf8WordRight(const std::string& s, size_t pos) {
  size_t i = pos;
  while (i < s.size()) {
    size_t len;
    unsigned int cp = Utf8DecodeAt(s, i, &len);
    if (IsWordBreakSpace(cp)) break;
    i += len;
  }
  while (i < s.size()) {
    size_t len;
    unsigned int cp = Utf8DecodeAt(s, i, &len);
    if (!IsWordBreakSpace(cp)) break;
    i += len;
  }
  return i;
}

// UTF-8 byte offset -> UTF-16 code unit count, the units RN's selection event
// expects (TextInputEventEmitter::Metrics::selectionRange mirrors iOS
// NSString / Android jchar, both UTF-16). A codepoint above U+FFFF is a
// surrogate PAIR (2 units, e.g. an emoji); everything else is 1 unit,
// regardless of its UTF-8 byte length -- so e-acute (2 UTF-8 bytes) counts
// as 1 unit and an emoji (4 UTF-8 bytes) counts as 2.
size_t Utf8OffsetToUtf16Units(const std::string& s, size_t byteOffset) {
  size_t units = 0;
  size_t i = 0;
  while (i < byteOffset && i < s.size()) {
    size_t len;
    unsigned int cp = Utf8DecodeAt(s, i, &len);
    units += (cp > 0xFFFF) ? 2 : 1;
    i += len;
  }
  return units;
}

// Escapes control bytes for the `rn-impeller: caret ...` log line so a
// newline/tab embedded in the buffer can never split the machine-readable
// line a gate greps. Multi-byte UTF-8 sequences pass through RAW (not
// escaped) so a gate can grep for the literal UTF-8 bytes of e.g. the emoji
// it typed.
std::string EscapeForLog(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (unsigned char c : s) {
    if (c == '\n') {
      out += "\\n";
    } else if (c == '\t') {
      out += "\\t";
    } else if (c == '\r') {
      out += "\\r";
    } else if (c < 0x20 || c == 0x7F) {
      char buf[8];
      std::snprintf(buf, sizeof(buf), "\\x%02x", c);
      out += buf;
    } else {
      out.push_back((char)c);
    }
  }
  return out;
}

}  // namespace

std::vector<std::string> FabricHost::knownComponentNames() {
  // MUST match the provider registry below. A component in one list and not
  // the other fails in a way that looks exactly like "the engine does not
  // have it": RN takes a fallback path, nothing mounts, nothing logs.
  std::vector<std::string> names = {"View", "RootView", "Paragraph", "Text",
                                     "RawText", "ScrollView", "TextInput"};
#if RNI_WITH_RNSVG
  names.insert(names.end(), {"RNSVGSvgView", "RNSVGGroup", "RNSVGPath",
                             "RNSVGRect", "RNSVGCircle", "RNSVGEllipse",
                             "RNSVGLine", "RNSVGDefs", "RNSVGLinearGradient",
                             "RNSVGRadialGradient"});
#endif
  return names;
}

FabricHost::FabricHost(react::ReactInstance& instance, SceneGraph* sceneGraph,
                       ImpellerTypographyContext typography, bool logMutations,
                       std::shared_ptr<DisplayMetrics> displayMetrics) {
  runtimeScheduler_ = instance.getRuntimeScheduler();
  sceneGraph_ = sceneGraph;
  logMutations_ = logMutations;

  auto providerRegistry =
      std::make_shared<const react::ComponentDescriptorProviderRegistry>();
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RootComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ViewComponentDescriptor>());
  // <Text>: Paragraph is the measurable leaf; Text/RawText are virtual.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ParagraphComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::TextComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RawTextComponentDescriptor>());
  // <ScrollView>. ENG-02.
  //
  // ⛔ REGISTRATION IS THE WHOLE FEATURE'S FLOOR, NOT A DETAIL.
  // Without this line a <ScrollView> still MOUNTS -- as a plain View with
  // ViewProps -- lays out, paints its children, and logs nothing wrong. It is
  // indistinguishable from "scrolling is unimplemented" by reading paint code,
  // which is why this add() is checked before any painter change.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ScrollViewComponentDescriptor>());
  // <TextInput>. ENG-01b.
  //
  // ⛔ REGISTRATION IS THE FLOOR, AND FOR TextInput IT IS ALSO WHERE MEASUREMENT
  // COMES FROM. BaseTextInputShadowNode::measureContent asks for a
  // TextLayoutManager via getManagerByName, so this descriptor MUST see the same
  // ImpellerTextLayoutManager that <Text> uses (inserted into contextContainer
  // below) or the field measures 0x0 and its own value text never lays out.
  // Unregistered, <TextInput> mounts as a plain View: it paints its border,
  // swallows every keystroke, and logs nothing wrong -- byte-for-byte the
  // read-only surface the Mac gate is currently pinned to.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::TextInputComponentDescriptor>());
#if RNI_WITH_RNSVG
  // RNSVGSvgView's ComponentDescriptor is OUR codegen output (react-native-svg's
  // Svg.js resolves to the platform-suffixed name, which only the codegen
  // emits); Group/Path use the vendor's own hand-written `using` aliases.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGSvgViewComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGGroupComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGPathComponentDescriptor>());
  // The basic shapes. Each is converted to path data in SceneGraph and painted
  // by the SAME fill/stroke code as <Path>, so registering them costs a line
  // here and nothing in the painter.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGRectComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGCircleComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGEllipseComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGLineComponentDescriptor>());
  // <Defs> paints nothing -- it is a container for definitions -- but it MUST
  // be registered or its gradient children never mount and every url(#id)
  // reference silently resolves to nothing.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGDefsComponentDescriptor>());
  // <Symbol> + <Use>: one asset, N mounting sites.
  //
  // ⚠️ REGISTERING THESE IS NOT WHAT FIXED THEM, AND THAT IS THE LESSON.
  // Unregistered, <Symbol> mounted with plain ViewProps and painted nothing OF
  // ITS OWN -- but its <Path> children were registered, so the painter walked
  // into them and drew the DEFINITION at the defs block's own coordinates. The
  // symptom was not a missing logo, it was a stray logo somewhere nobody was
  // probing. Registration lets us READ href/viewBox; SceneGraph's
  // isSvgDefinition early-return is what stops the leak. Both are required and
  // either alone is worse than neither.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGSymbolComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGUseComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGLinearGradientComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGRadialGradientComponentDescriptor>());
#endif
  providerRegistry_ = providerRegistry;

  auto contextContainer = std::make_shared<react::ContextContainer>();
  contextContainer->insert("DisplayMetrics", std::move(displayMetrics));
  // ⛔ MUST be inserted as the BASE-type shared_ptr. ParagraphComponentDescriptor
  // looks this up with getManagerByName<TextLayoutManager>, which does a
  // find<std::shared_ptr<TextLayoutManager>> — insert the derived type and the
  // lookup MISSES SILENTLY, RN news the platform/cxx stub instead, and every
  // <Text> measures 0x0 while the log stays clean.
  contextContainer->insert(
      "TextLayoutManager",
      std::shared_ptr<react::TextLayoutManager>(
          std::make_shared<ImpellerTextLayoutManager>(contextContainer, typography)));
  // Scheduler's ctor asserts on this key. Weak ptr, same shape as RCTInstance.
  contextContainer->insert(
      react::RuntimeSchedulerKey,
      std::weak_ptr<react::RuntimeScheduler>(runtimeScheduler_));

  react::SchedulerToolbox toolbox;
  toolbox.contextContainer = contextContainer;
  toolbox.componentRegistryFactory =
      [providerRegistry](const react::EventDispatcher::Weak& eventDispatcher,
                         const std::shared_ptr<const react::ContextContainer>& cc)
      -> react::SharedComponentDescriptorRegistry {
    return providerRegistry->createComponentDescriptorRegistry(
        {eventDispatcher, cc, nullptr});
  };
  // UNBUFFERED for the bindings executor: UIManagerBinding must be installed
  // BEFORE the main bundle evaluates, because ReactFabric grabs
  // global.nativeFabricUIManager at init. The buffered executor would queue it
  // behind the bundle and JS would find it missing.
  toolbox.bridgelessBindingsExecutor =
      std::optional<react::RuntimeExecutor>(instance.getUnbufferedRuntimeExecutor());
  toolbox.runtimeExecutor = instance.getBufferedRuntimeExecutor();
  toolbox.eventBeatFactory =
      [runtimeScheduler = runtimeScheduler_](
          std::shared_ptr<react::EventBeat::OwnerBox> ownerBox)
      -> std::unique_ptr<react::EventBeat> {
    return std::make_unique<ImpellerEventBeat>(std::move(ownerBox),
                                               *runtimeScheduler);
  };

  delegate_ = std::make_unique<ImpellerSchedulerDelegate>(sceneGraph, logMutations);
  scheduler_ = std::make_unique<react::Scheduler>(
      toolbox, /*animationDelegate*/ nullptr, delegate_.get());
  std::printf("[fabric] scheduler up (UIManagerBinding installed)\n");
  std::fflush(stdout);
}

FabricHost::~FabricHost() {
  stopSurface();
  // In-flight rendering-update lambdas captured a raw delegate pointer, and
  // the Scheduler only invalidates them behind a feature flag — drop the
  // delegate reference explicitly before tearing down.
  if (scheduler_) {
    scheduler_->setDelegate(nullptr);
  }
  scheduler_.reset();
  delegate_.reset();
}

void FabricHost::startSurface(const std::string& moduleName, int surfaceId,
                              float width, float height, float pointScaleFactor) {
  surfaceHandler_ = std::make_unique<react::SurfaceHandler>(
      moduleName, static_cast<react::SurfaceId>(surfaceId));
  scheduler_->registerSurface(*surfaceHandler_);

  // ⛔ WIDTH/HEIGHT ARRIVE IN DEVICE PIXELS; YOGA LAYS OUT IN POINTS.
  // React Native's unit is the POINT, and pointScaleFactor is how many device
  // pixels one point occupies. A 800x600 @2x surface is 400x300 POINTS, and a
  // `width: 200` view must occupy 200 points = 400 device pixels.
  //
  // Constraining Yoga with raw pixels while claiming scale 2 would lay out an
  // 800-point-wide tree and then rasterise it twice as large again — content
  // scaled to 4x, clipped on every side. Divide once, here, where the pixel
  // count enters the layout system.
  const float scale = pointScaleFactor > 0.0f ? pointScaleFactor : 1.0f;
  const float pointWidth = width / scale;
  const float pointHeight = height / scale;

  react::LayoutConstraints constraints;
  constraints.minimumSize = {.width = pointWidth, .height = pointHeight};
  constraints.maximumSize = {.width = pointWidth, .height = pointHeight};
  constraints.layoutDirection = react::LayoutDirection::LeftToRight;
  react::LayoutContext layoutContext;
  // Fabric rounds every layout value to a whole device pixel using this. Left
  // at 1.0 on a 2x display, a 0.5-point border rounds to 0 and vanishes rather
  // than becoming the 1 physical pixel it should be.
  layoutContext.pointScaleFactor = scale;
  surfaceHandler_->constraintLayout(constraints, layoutContext);

  surfaceHandler_->start();  // → AppRegistry.runApplication on the JS thread

  std::printf("[fabric] surface %d (%s) started %gx%g points @%gx (%gx%g px)\n",
              surfaceId, moduleName.c_str(), (double)pointWidth,
              (double)pointHeight, (double)scale, (double)width,
              (double)height);
  std::fflush(stdout);
}

bool FabricHost::updateSurface(int surfaceId, float width, float height,
                               float pointScaleFactor) {
  if (!surfaceHandler_) return false;

  // Identical arithmetic to startSurface, deliberately: the constraint that a
  // resize produces must be the one the same window would have produced at
  // launch, or the app renders differently depending on how it got to a size.
  const float scale = pointScaleFactor > 0.0f ? pointScaleFactor : 1.0f;
  const float pointWidth = width / scale;
  const float pointHeight = height / scale;

  react::LayoutConstraints constraints;
  constraints.minimumSize = {.width = pointWidth, .height = pointHeight};
  constraints.maximumSize = {.width = pointWidth, .height = pointHeight};
  constraints.layoutDirection = react::LayoutDirection::LeftToRight;
  react::LayoutContext layoutContext;
  layoutContext.pointScaleFactor = scale;
  surfaceHandler_->constraintLayout(constraints, layoutContext);

  std::printf("[fabric] surface %d resized %gx%g points @%gx (%gx%g px)\n",
              surfaceId, (double)pointWidth, (double)pointHeight, (double)scale,
              (double)width, (double)height);
  std::fflush(stdout);
  return true;
}

void FabricHost::stopSurface() {
  if (!surfaceHandler_) return;
  if (surfaceHandler_->getStatus() == react::SurfaceHandler::Status::Running) {
    surfaceHandler_->stop();
  }
  scheduler_->unregisterSurface(*surfaceHandler_);
  surfaceHandler_.reset();
}

int FabricHost::dispatchTouch(TouchPhase phase, float x, float y) {
  if (!sceneGraph_) return 0;
  // Hit-test to find the target, then hand off to the shared builder. The
  // resolution is the ONLY thing that differs between a fresh touch and a
  // captured drag move: this path finds whatever is under the point; the drag
  // path (dispatchCapturedMove) skips the hit test and reuses the pressed tag.
  const react::Tag target = sceneGraph_->hitTest(x, y);
  return dispatchTouchToTarget(phase, target, x, y);
}

// Build and schedule a touch to an ALREADY-RESOLVED target. Factored out of
// dispatchTouch so the drag-capture path can deliver Move/Up to the tag the
// press captured WITHOUT re-hit-testing -- duplicating this body would give the
// drag path its own copy of the emitter downcast, event shape and threading
// rules, and the two would drift. Returns the target, or 0 if it is 0 or has no
// touch emitter.
int FabricHost::dispatchTouchToTarget(TouchPhase phase, react::Tag target,
                                      float x, float y) {
  if (target == 0 || !sceneGraph_ || !runtimeScheduler_) return 0;

  auto emitter = sceneGraph_->eventEmitterFor(target);
  if (!emitter) return 0;
  // Not every descriptor emits touches. An unregistered or non-view component
  // yields a base EventEmitter, and this cast is what separates "nothing was
  // there" from "something was there but cannot receive a press" -- otherwise
  // the caller sees a hit and silently no handler, which is the exact
  // ambiguity that made this feature look implemented when it was not.
  auto touchEmitter =
      std::dynamic_pointer_cast<const react::TouchEventEmitter>(emitter);
  if (!touchEmitter) return 0;

  react::Touch touch{};
  touch.target = target;
  // One mouse == one finger, so a fixed identifier is correct here and must
  // stay stable across down/move/up: RN pairs a touchend with the touchstart
  // that shares its identifier, and a changing id yields a press that never
  // completes.
  touch.identifier = 0;
  touch.pagePoint = {x, y};
  touch.screenPoint = {x, y};
  // offsetPoint is target-relative. Left equal to pagePoint for now: resolving
  // it needs the target's absolute origin, which the hit walk knows but does
  // not yet return. onPress does not read it; a component measuring locationX
  // would. Called out rather than silently wrong.
  touch.offsetPoint = {x, y};
  touch.force = 1.0f;
  touch.timestamp =
      (react::Float)std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now().time_since_epoch())
          .count() /
      1000.0f;

  react::TouchEvent event{};
  event.changedTouches = {touch};
  // On Up/Cancel the contact is GONE, so `touches` (still on screen) must be
  // empty while changedTouches carries it. RN's Pressability derives release
  // from that emptiness; sending a still-present touch here yields a press
  // that highlights and never fires.
  const bool ending =
      phase == TouchPhase::Up || phase == TouchPhase::Cancel;
  if (!ending) {
    event.touches = {touch};
    event.targetTouches = {touch};
  }

  // Hop to the JS thread. The emitter must not be invoked from the event
  // thread: it reaches into the runtime.
  runtimeScheduler_->scheduleWork(
      [touchEmitter, event, phase](facebook::jsi::Runtime&) {
        switch (phase) {
          case TouchPhase::Down:
            touchEmitter->onTouchStart(event);
            break;
          case TouchPhase::Move:
            touchEmitter->onTouchMove(event);
            break;
          case TouchPhase::Up:
            touchEmitter->onTouchEnd(event);
            break;
          case TouchPhase::Cancel:
            touchEmitter->onTouchCancel(event);
            break;
        }
      });
  return (int)target;
}

// ENG-DRAG (P0). Press-drag-release capture. A real UI toolkit routes every
// move BETWEEN a press and its release to the node the press landed on, even
// after the cursor leaves that node's bounds -- a slider you drag past its
// track still tracks, a button you press and slide off still gets the release
// (as a cancel/out event). Impeller has no PointerDispatcher, whose whole job
// on other platforms is exactly this retention, so the host replicates it: the
// press captures its tag, held moves and the release go to THAT tag with NO
// re-hit-test, and release clears the capture.
//
// ⛔ WHY NOT JUST HIT-TEST EACH MOVE. dispatchTouch resolves the target from
// the point every call. Feed it mid-drag coordinates and it retargets to
// whatever is now under the cursor -- so a drag that leaves the pressed control
// silently hands the Move/Up to a sibling, or to nothing, and the gesture the
// user is performing on control A is delivered to control B. That is the exact
// defect this captures against: move-target MUST equal down-target for the life
// of the press, which is what ci-drag.sh asserts.
int FabricHost::beginTouchCapture(float x, float y) {
  if (!sceneGraph_) return 0;
  const react::Tag target = sceneGraph_->hitTest(x, y);
  // Dispatch the Down through the resolving path (it downcasts the emitter and
  // returns 0 for a non-touch target), and capture ONLY if a real touchable
  // took it. Capturing a tag with no emitter would strand a drag that can
  // deliver nothing -- the same discrimination dispatchTouch already makes.
  const int hit = dispatchTouchToTarget(TouchPhase::Down, target, x, y);
  capturedTag_ = hit;  // 0 when the press landed on empty space / a non-touch
  return hit;
}

// A move while a press is held. Routes to the CAPTURED tag with no hit test, so
// the drag stays on the pressed control wherever the cursor goes. Returns the
// captured tag (== the down target), or 0 if no press is currently held -- a
// bare hover, which the caller must route to dispatchHover instead.
int FabricHost::dispatchCapturedMove(float x, float y) {
  if (capturedTag_ == 0) return 0;
  return dispatchTouchToTarget(TouchPhase::Move, (react::Tag)capturedTag_, x, y);
}

// The release that ends a press. Delivers the Up to the captured tag (again no
// hit test -- a release off the control still belongs to it) and clears the
// capture so the next move is a plain hover again. Returns the tag the Up went
// to, or 0 if nothing was captured.
int FabricHost::endTouchCapture(float x, float y) {
  if (capturedTag_ == 0) return 0;
  const int tag = capturedTag_;
  dispatchTouchToTarget(TouchPhase::Up, (react::Tag)tag, x, y);
  capturedTag_ = 0;
  return tag;
}

// True while a press is held, so the windowed host knows whether a cursor-move
// is a drag (route to the captured tag) or a hover (route to dispatchHover).
bool FabricHost::isTouchCaptured() const { return capturedTag_ != 0; }

// <ScrollView>. ENG-02.
//
// ⛔ TWO EFFECTS, AND THEY MUST BOTH HAPPEN OR THE FEATURE IS A LIE.
//   1. The SceneGraph offset moves, so the next paint shows different rows.
//   2. onScroll fires in JS, so React state that tracks scroll position (sticky
//      headers, "load more" at the end, a progress bar) updates.
// An engine that only does (1) scrolls beautifully and breaks every list that
// reacts to scrolling; one that only does (2) reports motion that never
// happened. Both are indistinguishable from working if you check only the
// other one.
int FabricHost::dispatchScroll(float x, float y, float dx, float dy) {
  if (!sceneGraph_ || !runtimeScheduler_) return 0;

  const auto res = sceneGraph_->scrollBy(x, y, dx, dy);
  if (res.tag == 0) return 0;

  auto emitter = sceneGraph_->eventEmitterFor(res.tag);
  if (!emitter) return 0;
  // Same discrimination as dispatchTouch: an UNREGISTERED ScrollView mounts
  // with a base ViewEventEmitter, so this cast is what separates "there is no
  // scroll view here" from "there is one but it cannot report scrolling".
  // Without the descriptor registration in setup() this cast fails every time
  // while the offset above still moves -- pixels would scroll and JS would
  // never hear about it.
  auto scrollEmitter =
      std::dynamic_pointer_cast<const react::ScrollViewEventEmitter>(emitter);
  if (!scrollEmitter) return 0;

  react::ScrollEvent event{};
  // Both axes reported: a horizontal list drives contentOffset.x, and a JS
  // handler reading nativeEvent.contentOffset.x for a sticky column header or a
  // paged carousel index would otherwise always read zero while the pixels slid.
  event.contentOffset = {(react::Float)res.offsetX, (react::Float)res.offsetY};
  event.contentSize = {(react::Float)res.contentWidth,
                       (react::Float)res.contentHeight};
  event.containerSize = {(react::Float)res.containerWidth,
                         (react::Float)res.containerHeight};
  event.zoomScale = 1.0f;
  event.timestamp =
      (react::Float)std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now().time_since_epoch())
          .count() /
      1000.0f;

  // Hop to the JS thread, for the same reason dispatchTouch does: the emitter
  // reaches into the runtime.
  runtimeScheduler_->scheduleWork(
      [scrollEmitter, event](facebook::jsi::Runtime&) {
        scrollEmitter->onScroll(event);
      });
  return (int)res.tag;
}

// ENG-09 hover/cursor.
bool FabricHost::emitPointer(int tag, bool enter, float x, float y) {
  if (tag == 0 || !sceneGraph_ || !runtimeScheduler_) return false;

  auto emitter = sceneGraph_->eventEmitterFor((react::Tag)tag);
  if (!emitter) return false;
  // Same discrimination as dispatchTouch: only a TouchEventEmitter can carry a
  // pointer event. A base EventEmitter (unregistered / non-view node) cannot,
  // and dispatching to it would be a silent no-op that looks like a delivered
  // hover -- which is exactly the ambiguity the touch path already refuses.
  auto touchEmitter =
      std::dynamic_pointer_cast<const react::TouchEventEmitter>(emitter);
  if (!touchEmitter) return false;

  react::PointerEvent event{};
  // W3C: a mouse pointer's primary id is 1 in RN. Stable across enter/leave.
  event.pointerId = 1;
  event.pointerType = "mouse";
  event.clientPoint = {x, y};
  event.screenPoint = {x, y};
  // offsetPoint is target-relative; left equal to clientPoint for the same
  // reason dispatchTouch leaves it equal to pagePoint -- the hit walk knows the
  // target origin but does not return it yet, and onPointerEnter/Leave do not
  // read it. Called out rather than silently wrong.
  event.offsetPoint = {x, y};
  event.pressure = 0.0f;
  // No button is held during a hover. RN's buttons bitmask: 0 = none.
  event.buttons = 0;
  event.width = 1.0f;
  event.height = 1.0f;

  runtimeScheduler_->scheduleWork(
      [touchEmitter, event, enter](facebook::jsi::Runtime&) {
        if (enter) {
          touchEmitter->onPointerEnter(event);
        } else {
          touchEmitter->onPointerLeave(event);
        }
      });
  return true;
}

// ENG-09 hover/cursor. Move the retained hovered tag; emit leave/enter only on
// a transition. The two effects that must both hold: (1) the OLD view gets a
// pointerleave so its hover styling clears, (2) the NEW view gets a
// pointerenter so its hover styling applies. A move within the same view emits
// NEITHER -- that is what keeps the per-move path quiet.
FabricHost::HoverResult FabricHost::dispatchHover(float x, float y) {
  HoverResult result{};
  if (!sceneGraph_) return result;

  react::Tag target = sceneGraph_->hitTest(x, y);
  // A hit that lands on a node with no touch emitter cannot be a hover target:
  // it can neither receive a pointerenter nor, later, a pointerleave, so
  // retaining it would strand a leave forever. Collapse it to "nothing", the
  // same as hovering empty space -- and let the cursor fall back to arrow.
  if (target != 0) {
    auto emitter = sceneGraph_->eventEmitterFor(target);
    if (!std::dynamic_pointer_cast<const react::TouchEventEmitter>(emitter)) {
      target = 0;
    }
  }

  result.tag = (int)target;
  result.cursorKind = sceneGraph_->cursorKindFor(target);

  if ((int)target == hoveredTag_) {
    // No transition. Silent by construction: this is the common per-move case.
    return result;
  }

  // Leave the old, enter the new -- in that order, matching the DOM, so a view
  // that reacts to both sees leave-then-enter rather than an interleaving.
  if (hoveredTag_ != 0 && emitPointer(hoveredTag_, /*enter=*/false, x, y)) {
    result.left = hoveredTag_;
  }
  if (target != 0 && emitPointer((int)target, /*enter=*/true, x, y)) {
    result.entered = (int)target;
  }
  hoveredTag_ = (int)target;
  return result;
}

// ENG-09 hover/cursor. Cursor left the window: leave the hovered view (if any)
// and forget it.
int FabricHost::clearHover() {
  if (hoveredTag_ == 0) return 0;
  const int was = hoveredTag_;
  // Coordinates are meaningless here (the cursor is outside), but a
  // pointerleave still carries the last-known point; 0,0 is as good as any and
  // no handler reads it on a leave.
  emitPointer(was, /*enter=*/false, 0.0f, 0.0f);
  hoveredTag_ = 0;
  return was;
}

// <TextInput>. ENG-01b. Focus the field under the point, or blur.
//
// ⛔ A TextInput IS identified by its emitter type, not its component name.
// hitTest returns the topmost tag; a TextInputEventEmitter downcast is what
// separates a real editable field (registered descriptor -> concrete emitter)
// from a plain View that merely happens to sit under the cursor. Same
// discrimination discipline as dispatchTouch/dispatchHover.
int FabricHost::focusTextInputAt(float x, float y) {
  if (!sceneGraph_) return 0;
  react::Tag target = sceneGraph_->hitTest(x, y);
  bool isField = false;
  if (target != 0) {
    auto emitter = sceneGraph_->eventEmitterFor(target);
    isField = (bool)std::dynamic_pointer_cast<
        const react::TextInputEventEmitter>(emitter);
  }
  if (!isField) {
    // A click outside any field blurs the current one, matching every desktop
    // text field: onBlur fires and the caret disappears.
    if (react::Tag prev = sceneGraph_->focusedTextInput()) {
      auto emitter = sceneGraph_->eventEmitterFor(prev);
      if (auto te = std::dynamic_pointer_cast<
              const react::TextInputEventEmitter>(emitter)) {
        react::TextInputEventEmitter::Metrics m{};
        m.text = sceneGraph_->textInputValueFor(prev);
        m.eventCount = ++tiEventCount_;
        runtimeScheduler_->scheduleWork(
            [te, m](facebook::jsi::Runtime&) { te->onBlur(m); });
      }
    }
    sceneGraph_->clearTextInputFocus();
    return 0;
  }
  sceneGraph_->setTextInputFocus(target);
  auto emitter = sceneGraph_->eventEmitterFor(target);
  if (auto te = std::dynamic_pointer_cast<
          const react::TextInputEventEmitter>(emitter)) {
    react::TextInputEventEmitter::Metrics m{};
    m.text = sceneGraph_->textInputValueFor(target);
    m.eventCount = ++tiEventCount_;
    runtimeScheduler_->scheduleWork(
        [te, m](facebook::jsi::Runtime&) { te->onFocus(m); });
  }
  return (int)target;
}

bool FabricHost::hasTextInputFocus() {
  return sceneGraph_ && sceneGraph_->focusedTextInput() != 0;
}

// <TextInput>. ENG-01b. Non-mutating: is there a REAL text field under (x,y)?
// The headless --type harness polls this to settle the mount before its first
// focus. hitTest alone is not enough -- a full-surface background <View> hits at
// every point, so a bare "hitTest != 0" resolves the instant the root mounts,
// long before the field does. This checks the hit node is actually a
// TextInputEventEmitter, i.e. focusTextInputAt would succeed here.
bool FabricHost::isTextInputAt(float x, float y) {
  if (!sceneGraph_) return false;
  react::Tag target = sceneGraph_->hitTest(x, y);
  if (target == 0) return false;
  auto emitter = sceneGraph_->eventEmitterFor(target);
  return (bool)std::dynamic_pointer_cast<const react::TextInputEventEmitter>(
      emitter);
}

// <TextInput>. ENG-01b + item 2a. One editing keystroke OR caret move.
//
// ⛔ THREE EFFECTS, EACH INDEPENDENTLY OBSERVABLE (extends dispatchScroll's
// two-effect rule):
//   1. The SceneGraph edit buffer/caret changes, so the next paint shows the
//      new glyphs AND the caret at its new index -- painted by a prefix-width
//      measurement (SceneGraph.cpp), not pinned to end-of-text.
//   2. onSelectionChange fires with a COLLAPSED {start,end} in UTF-16 CODE
//      UNITS (RN convention: TextInputEventEmitter::Metrics::selectionRange
//      mirrors iOS NSString / Android jchar, not UTF-8 bytes) for EVERY
//      action here that reaches a focused field -- including a pure caret
//      move that never touches the buffer (Left/Right/word/Home/End), since
//      the caret moved even though the text did not.
//   3. onChange fires ONLY when the text ACTUALLY changed (Insert/Backspace/
//      DeleteForward). A pure caret move must never fire onChange -- there is
//      no text delta, and firing it anyway would make a cursor move look like
//      an edit to JS.
// Effect (1) alone types beautifully into a field JS never hears about;
// effect (3) alone reports text that is not on screen. Enter is the
// exception: it emits onSubmitEditing and touches neither buffer nor caret.
//
// ⛔ ONE EDITING PATH PER KEY -- see the header. MoveLeft/Right/Word*/Home/
// End/DeleteForward are reached ONLY from dispatchKeyEvent's caret-routing
// branch below (ArrowLeft/Right/Home/End/Delete); Backspace/Submit/Newline
// stay reachable ONLY from the legacy GlfwSurface::keyHandler_ path
// (main.cpp's setKeyHandler, Backspace/Enter). The two sets of W3C key names
// are disjoint, so a single physical keystroke can never reach this function
// twice for the same press.
int FabricHost::dispatchKey(KeyAction action, unsigned int codepoint) {
  if (!sceneGraph_ || !runtimeScheduler_) return 0;
  react::Tag tag = sceneGraph_->focusedTextInput();
  if (tag == 0) return 0;

  auto emitter = sceneGraph_->eventEmitterFor(tag);
  auto te =
      std::dynamic_pointer_cast<const react::TextInputEventEmitter>(emitter);
  if (!te) return 0;

  if (action == KeyAction::Submit || action == KeyAction::Newline) {
    // Single-line field: a bare Enter (or Shift+Enter, routed the same until
    // a real multiline buffer exists) submits rather than inserting or
    // moving. Buffer and caret are untouched.
    react::TextInputEventEmitter::Metrics m{};
    m.text = sceneGraph_->textInputValueFor(tag);
    m.eventCount = ++tiEventCount_;
    runtimeScheduler_->scheduleWork(
        [te, m](facebook::jsi::Runtime&) { te->onSubmitEditing(m); });
    return (int)tag;
  }

  std::string value = sceneGraph_->textInputValueFor(tag);
  size_t caret = sceneGraph_->textInputCaretFor(tag);
  if (caret > value.size()) caret = value.size();  // defensive clamp

  bool textChanged = false;
  switch (action) {
    case KeyAction::InsertChar: {
      // Any Unicode scalar value >= 0x20 except 0x7F (DEL) and surrogate
      // halves -- see Utf8EncodeAppend's header. Inserted AT THE CARET, not
      // appended at the end.
      std::string encoded;
      if (Utf8EncodeAppend(&encoded, codepoint)) {
        value.insert(caret, encoded);
        caret += encoded.size();
        textChanged = true;
      }
      break;
    }
    case KeyAction::Backspace: {
      // Deletes ONE WHOLE CODEPOINT before the caret, never a single byte --
      // popping a byte off a multi-byte sequence (the pre-item-2a behaviour)
      // corrupts the buffer into invalid UTF-8.
      if (caret > 0) {
        size_t prev = Utf8PrevBoundary(value, caret);
        value.erase(prev, caret - prev);
        caret = prev;
        textChanged = true;
      }
      break;
    }
    case KeyAction::DeleteForward: {
      if (caret < value.size()) {
        size_t next = Utf8NextBoundary(value, caret);
        value.erase(caret, next - caret);
        textChanged = true;
      }
      break;
    }
    case KeyAction::MoveLeft:
      caret = Utf8PrevBoundary(value, caret);
      break;
    case KeyAction::MoveRight:
      caret = Utf8NextBoundary(value, caret);
      break;
    case KeyAction::MoveWordLeft:
      caret = Utf8WordLeft(value, caret);
      break;
    case KeyAction::MoveWordRight:
      caret = Utf8WordRight(value, caret);
      break;
    case KeyAction::MoveHome:
      caret = 0;
      break;
    case KeyAction::MoveEnd:
      caret = value.size();
      break;
    case KeyAction::Submit:
    case KeyAction::Newline:
      break;  // handled above; unreachable here
  }

  // Apply to the paint buffer first so a paint scheduled by the JS re-render
  // below never briefly shows the pre-edit string or the caret at its old
  // index. setTextInputEdit clamps caret to value.size() defensively too.
  sceneGraph_->setTextInputEdit(tag, value, caret);
  printf("rn-impeller: caret tag=%d pos=%zu text=%s\n", (int)tag, caret,
         EscapeForLog(value).c_str());
  fflush(stdout);

  react::TextInputEventEmitter::Metrics m{};
  m.text = value;
  m.eventCount = ++tiEventCount_;
  // UTF-16 code units, per RN's own selectionRange convention -- NOT the
  // UTF-8 byte offset the engine stores internally.
  const int caretUnits = (int)Utf8OffsetToUtf16Units(value, caret);
  m.selectionRange.location = caretUnits;
  m.selectionRange.length = 0;  // collapsed: caret only, no selection (2a)
  runtimeScheduler_->scheduleWork([te, m, textChanged](facebook::jsi::Runtime&) {
    // onChange is what RN's TextInput.js turns into onChangeText(text): its
    // _onChange reads nativeEvent.text and calls props.onChangeText. Fired
    // ONLY when the text changed -- see the header's effect (3).
    if (textChanged) te->onChange(m);
    // onSelectionChange fires unconditionally: the caret moved (or stayed,
    // for a no-op edit at a buffer edge) either way.
    te->onSelectionChange(m);
  });
  return (int)tag;
}

// desktop-input-gap P0 item 1. Full keyboard forwarding to JS -- see the
// header for the two-channel design (TextInput onKeyPress + a generic
// keyDown/keyUp dispatchEvent) and why RN 0.86's C++ BaseViewEventEmitter
// cannot carry a real onKeyDown method.
int FabricHost::dispatchKeyEvent(const std::string& key,
                                 const std::string& code, KeyEventPhase phase,
                                 const KeyModifiers& mods) {
  if (!sceneGraph_ || !runtimeScheduler_) return 0;
  // Focused field first; fall back to the surface root so a key event
  // always has SOMEWHERE to land rather than being silently swallowed the
  // instant nothing has focus -- the ask explicitly requires this fallback.
  react::Tag target = sceneGraph_->focusedTextInput();
  if (target == 0) target = sceneGraph_->rootTag();
  if (target == 0) return 0;

  auto emitter = sceneGraph_->eventEmitterFor(target);
  if (!emitter) return 0;

  // desktop-input-gap item 2a. Caret navigation + forward Delete, routed
  // through dispatchKey -- the ONE editing path for these keys (see its
  // header). Down/Repeat only, the same discipline the legacy Backspace/
  // Enter handler uses (GlfwSurface.cpp's `ev.phase != KeyPhase::Up`), so a
  // held arrow key repeats the move and a release does nothing. Only reached
  // when a TextInput is ACTUALLY focused -- `target` above may have fallen
  // back to the surface root, which must never receive a caret move.
  //
  // Word move: Alt+Arrow on darwin (__APPLE__), Ctrl+Arrow elsewhere --
  // matching the platform convention neither fork's own keyboard shortcuts
  // deviate from (macOS reserves Ctrl+Arrow for Mission Control/Spaces).
  // Line start/end: Home/End on every platform, PLUS Cmd(meta)+Left/Right on
  // darwin (there is no Linux/Windows convention for meta+Left/Right moving
  // the caret, so it is intentionally NOT wired there and falls through to a
  // plain character move).
  if (sceneGraph_->focusedTextInput() != 0 && phase != KeyEventPhase::Up) {
#if defined(__APPLE__)
    const bool wordMod = mods.alt;
#else
    const bool wordMod = mods.ctrl;
#endif
    KeyAction caretAction = KeyAction::MoveLeft;
    bool isCaretKey = true;
    if (key == "ArrowLeft") {
#if defined(__APPLE__)
      caretAction = mods.meta        ? KeyAction::MoveHome
                  : wordMod          ? KeyAction::MoveWordLeft
                                     : KeyAction::MoveLeft;
#else
      caretAction = wordMod ? KeyAction::MoveWordLeft : KeyAction::MoveLeft;
#endif
    } else if (key == "ArrowRight") {
#if defined(__APPLE__)
      caretAction = mods.meta        ? KeyAction::MoveEnd
                  : wordMod          ? KeyAction::MoveWordRight
                                     : KeyAction::MoveRight;
#else
      caretAction = wordMod ? KeyAction::MoveWordRight : KeyAction::MoveRight;
#endif
    } else if (key == "Home") {
      caretAction = KeyAction::MoveHome;
    } else if (key == "End") {
      caretAction = KeyAction::MoveEnd;
    } else if (key == "Delete") {
      caretAction = KeyAction::DeleteForward;
    } else {
      isCaretKey = false;
    }
    if (isCaretKey) dispatchKey(caretAction, 0);
  }

  // (a) TextInput onKeyPress. Down/Repeat only -- onKeyPress has no release
  // concept in RN core (see RN's KeyPressMetrics: text + eventCount, no
  // phase). Only fires when the target IS a focused TextInput; the root
  // fallback above is a base EventEmitter and this cast simply fails for it,
  // exactly the "there but cannot receive this event" discrimination every
  // other dispatch path in this file already makes.
  //
  // `text` mirrors RN's OWN keyPressMetricsPayload derivation exactly
  // (TextInputEventEmitter.cpp: empty->"Backspace", "\n"->"Enter",
  // "\t"->"Tab", "\x1B"->"Escape", else passed through) so the emitter's
  // built-in logic reproduces our W3C `key` string byte for byte instead of
  // this file guessing at RN's internal convention a second time.
  if (phase != KeyEventPhase::Up) {
    if (auto te = std::dynamic_pointer_cast<const react::TextInputEventEmitter>(
            emitter)) {
      std::string text;
      if (key == "Backspace") {
        text = "";
      } else if (key == "Enter") {
        text = "\n";
      } else if (key == "Tab") {
        text = "\t";
      } else if (key == "Escape") {
        text = "\x1B";
      } else {
        text = key;
      }
      react::TextInputEventEmitter::KeyPressMetrics kpm{};
      kpm.text = text;
      kpm.eventCount = ++tiEventCount_;
      runtimeScheduler_->scheduleWork(
          [te, kpm](facebook::jsi::Runtime&) { te->onKeyPress(kpm); });
    }
  }

  // (b) Generic keyDown/keyUp, delivered to WHATEVER is at `target` --
  // TextInput or plain View alike -- via the base EventEmitter::dispatchEvent
  // every emitter inherits. `dispatchEvent("keyDown", ...)` normalises
  // through EventEmitter::normalizeEventType's "no on/top prefix -> add top"
  // rule to "topKeyDown"/"topKeyUp", matching the bubbling registration this
  // commit adds to the view-config shim (package/src/metro-shims -- see
  // PLATFORM_FORKED's BaseViewConfig.ios.js redirect) so a plain <View
  // onKeyDown>/<View onKeyUp> receives it. Payload shape follows
  // react-native-windows: key, code, altKey, ctrlKey, metaKey, shiftKey,
  // plus capsLockKey and repeat (neither fork's payload carries these, but
  // the gap doc's ask requires them).
  const std::string eventName = phase == KeyEventPhase::Up ? "keyUp" : "keyDown";
  const bool repeat = phase == KeyEventPhase::Repeat;
  runtimeScheduler_->scheduleWork(
      [emitter, eventName, key, code, mods, repeat](facebook::jsi::Runtime&) {
        emitter->dispatchEvent(
            eventName,
            [key, code, mods, repeat](facebook::jsi::Runtime& runtime) {
              auto payload = facebook::jsi::Object(runtime);
              payload.setProperty(
                  runtime, "key",
                  facebook::jsi::String::createFromUtf8(runtime, key));
              payload.setProperty(
                  runtime, "code",
                  facebook::jsi::String::createFromUtf8(runtime, code));
              payload.setProperty(runtime, "shiftKey", mods.shift);
              payload.setProperty(runtime, "ctrlKey", mods.ctrl);
              payload.setProperty(runtime, "altKey", mods.alt);
              payload.setProperty(runtime, "metaKey", mods.meta);
              payload.setProperty(runtime, "capsLockKey", mods.capsLock);
              payload.setProperty(runtime, "repeat", repeat);
              return facebook::jsi::Value(std::move(payload));
            });
      });

  return (int)target;
}

}  // namespace rni
