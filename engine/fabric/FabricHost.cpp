#include <algorithm>
#include <cmath>
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
#include "SwitchShadowNode.h"  // ENG-15
#include "ActivityIndicatorShadowNode.h"  // A20
#include "ModalHostShadowNode.h"  // A22
#include <react/renderer/components/image/ImageComponentDescriptor.h>  // A19
#include <react/renderer/imagemanager/ImageManager.h>
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
#include "fabric/WorldShadowNode.h"
#endif

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <future>
#include <thread>
#include <unordered_set>

#include "modules/CoreModules.h"
#include "scenegraph/SceneGraph.h"
#include "text/ImpellerTextLayoutManager.h"

namespace rni {

namespace react = facebook::react;

namespace {

// ⛔ EXIT RACE (found by ci-click-caret: SIGSEGV after RN_IMPELLER_WINDOW_OK).
// The Scheduler registers its EventPerformanceLogger as the RuntimeScheduler's
// event-timing delegate; every JS tick ends in RuntimeScheduler_Modern::
// updateRendering(), which LOADS that raw pointer and then calls
// dispatchPendingEventTimingEntries() on it (a mutex + a walk of in-flight
// events -- longer after clicks/keys). ~Scheduler nulls the pointer but does
// not wait for a tick that already loaded it, so destroying the Scheduler from
// the main thread while the JS thread is inside that call frees the logger
// under it. ~FabricHost therefore nulls the delegate itself and then DRAINS
// the JS thread (a barrier task) before the Scheduler goes away.
//
// Test probe (RNI_TEST_EXIT_RACE_MS=N, gates only): replaces the delegate with
// one that, once armed at teardown, parks the JS thread for N ms inside the
// exact window above, then checks whether the Scheduler was destroyed while
// it was parked. Deliberately leaked so the probe itself is never freed: the
// detection is the torn-down flag, not a read of freed memory.
std::atomic<bool> gSchedulerTornDown{false};

class ExitRaceProbe : public react::RuntimeSchedulerEventTimingDelegate {
 public:
  explicit ExitRaceProbe(int ms) : ms_(ms) {}
  void dispatchPendingEventTimingEntries(
      react::HighResTimeStamp,
      const std::unordered_set<react::SurfaceId>&) override {
    if (!armed.load()) return;
    if (!entered.exchange(true)) {
      std::printf("rn-impeller: exit_race_probe entered (parking the JS tick %d ms)\n", ms_);
      std::fflush(stdout);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(ms_));
    if (gSchedulerTornDown.load()) {
      std::printf("rn-impeller: exit_race_probe USE-AFTER-FREE: the Scheduler was "
                  "destroyed while a JS tick was inside its event-timing delegate\n");
      std::fflush(stdout);
      std::_Exit(139);
    }
    if (!reportedClean.exchange(true)) {
      std::printf("rn-impeller: exit_race_probe tick finished before teardown\n");
      std::fflush(stdout);
    }
  }
  std::atomic<bool> armed{false};
  std::atomic<bool> entered{false};
  std::atomic<bool> reportedClean{false};

 private:
  int ms_;
};
ExitRaceProbe* gExitRaceProbe = nullptr;  // leaked on purpose (see above)

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
  // item 7: view commands (ScrollView scrollTo/scrollToEnd, TextInput
  // focus/blur/setTextAndSelection). This was an empty stub, so every
  // ref.scrollTo(), ref.focus() and controlled `selection`/`value` update
  // that RN routes through a command was silently dropped. Runs on the JS
  // thread; the host applies it on the main thread.
  std::function<void(FabricHost::ViewCommand)> commandHandler_;
  void schedulerDidDispatchCommand(const react::ShadowView& shadowView,
                                   const std::string& commandName,
                                   const folly::dynamic& args) override {
    if (!commandHandler_) return;
    FabricHost::ViewCommand cmd;
    cmd.tag = (int)shadowView.tag;
    cmd.name = commandName;
    if (args.isArray()) {
      for (const auto& a : args) {
        if (a.isNumber()) {
          cmd.nums.push_back(a.asDouble());
        } else if (a.isBool()) {
          cmd.bools.push_back(a.asBool());
        } else if (a.isString()) {
          cmd.hasText = true;
          cmd.text = a.asString();
        }
      }
    }
    commandHandler_(std::move(cmd));
  }
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

// item 5 (paste newline flattening). Single-line field: every CR, LF or
// CRLF RUN (one or more, in any mix) becomes exactly ONE space -- not one
// space per character, or "a\nb\r\nc" would paste as "a  b  c" instead of
// the single-space-per-break "a b c" the gate asserts. Every OTHER control
// byte < 0x20 is DROPPED, not replaced. Pure byte-level scan: CR/LF/other
// control bytes are all single-byte ASCII (< 0x80), so this never needs to
// decode a UTF-8 sequence and can never split one -- a continuation byte
// (0x80-0xBF) is always >= 0x20 and passes through untouched either way.
std::string FlattenNewlinesForSingleLine(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  bool inBreakRun = false;
  for (unsigned char c : s) {
    if (c == '\r' || c == '\n') {
      if (!inBreakRun) {
        out.push_back(' ');
        inBreakRun = true;
      }
      continue;
    }
    inBreakRun = false;
    if (c < 0x20) continue;  // drop other control bytes, do not replace them
    out.push_back((char)c);
  }
  return out;
}

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

// item 4b: the word CONTAINING pos (double-click). A word is a maximal run
// of non-space codepoints; clicking on a space selects that space run. pos is
// a codepoint boundary; the codepoint AT pos decides (at the end of the text,
// the codepoint before it).
size_t Utf8WordStartAt(const std::string& s, size_t pos) {
  if (s.empty()) return 0;
  size_t probe = pos >= s.size() ? Utf8PrevBoundary(s, s.size()) : pos;
  size_t len;
  const bool space = IsWordBreakSpace(Utf8DecodeAt(s, probe, &len));
  size_t i = probe;
  while (i > 0) {
    size_t prev = Utf8PrevBoundary(s, i);
    if (IsWordBreakSpace(Utf8DecodeAt(s, prev, &len)) != space) break;
    i = prev;
  }
  return i;
}

size_t Utf8WordEndAt(const std::string& s, size_t pos) {
  if (s.empty()) return 0;
  size_t probe = pos >= s.size() ? Utf8PrevBoundary(s, s.size()) : pos;
  size_t len;
  const bool space = IsWordBreakSpace(Utf8DecodeAt(s, probe, &len));
  size_t i = probe;
  while (i < s.size()) {
    if (IsWordBreakSpace(Utf8DecodeAt(s, i, &len)) != space) break;
    i = Utf8NextBoundary(s, i);
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

// item 7: inverse of Utf8OffsetToUtf16Units. Clamps to the end; never lands
// inside a UTF-8 sequence, and a unit count that would split a surrogate pair
// rounds up past the codepoint.
size_t Utf16UnitsToUtf8Offset(const std::string& s, size_t units) {
  size_t i = 0, u = 0;
  while (i < s.size() && u < units) {
    size_t len;
    const unsigned int cp = Utf8DecodeAt(s, i, &len);
    u += cp >= 0x10000 ? 2 : 1;
    i += len;
  }
  return i;
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
  // <world>. ENG-09. WorldShadowNode borrows RNSVGImageProps/EventEmitter
  // (see fabric/WorldShadowNode.h), so it is only declared -- and only
  // registered below -- when RNI_WITH_RNSVG pulls those generated types in.
  names.push_back("world");
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
  // <Switch>. ENG-15. Same floor as above: unregistered, a <Switch> mounts as
  // a plain View, measures 0 x 0 and paints nothing (audit tile 62). See
  // fabric/SwitchShadowNode.h.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ImpellerSwitchComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ImpellerActivityIndicatorComponentDescriptor>());
  // <Modal>. A22: a window-sized layout root painted after the app root.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ImpellerModalHostComponentDescriptor>());
  // <Image>. A19: RN's ImageShadowNode ("Image", from RCTImageView) with OUR
  // ImageManager (fabric/platform/impeller/.../ImageManager.cpp).
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ImageComponentDescriptor>());
#if RNI_WITH_RNSVG
  // <world>. ENG-09. See fabric/WorldShadowNode.h for why this borrows
  // RNSVGImageProps/EventEmitter rather than getting its own codegen pair --
  // registration here is the floor, same as every other host component:
  // unregistered, a mounted <world> falls back to a plain View with
  // ViewProps and paints nothing OF ITS OWN, silently.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::WorldComponentDescriptor>());
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
  contextContainer->insert(react::ImageManagerKey,
                           std::make_shared<react::ImageManager>(contextContainer));
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

  {
    auto d = std::make_unique<ImpellerSchedulerDelegate>(sceneGraph, logMutations);
    d->commandHandler_ = [this](ViewCommand cmd) { postCommand(std::move(cmd)); };
    delegate_ = std::move(d);
  }
  scheduler_ = std::make_unique<react::Scheduler>(
      toolbox, /*animationDelegate*/ nullptr, delegate_.get());
  std::printf("[fabric] scheduler up (UIManagerBinding installed)\n");
  std::fflush(stdout);
  if (const char* ms = std::getenv("RNI_TEST_EXIT_RACE_MS")) {
    gExitRaceProbe = new ExitRaceProbe(std::atoi(ms) > 0 ? std::atoi(ms) : 300);
    runtimeScheduler_->setEventTimingDelegate(gExitRaceProbe);
    std::printf("rn-impeller: exit_race_probe installed\n");
    std::fflush(stdout);
  }
}

FabricHost::~FabricHost() {
  if (gExitRaceProbe && runtimeScheduler_) {
    // Test only: park a JS tick inside the event-timing delegate right now.
    gExitRaceProbe->armed = true;
    runtimeScheduler_->scheduleWork([](facebook::jsi::Runtime&) {});
    for (int i = 0; i < 400 && !gExitRaceProbe->entered.load(); ++i) {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
  }
  stopSurface();
  // In-flight rendering-update lambdas captured a raw delegate pointer, and
  // the Scheduler only invalidates them behind a feature flag — drop the
  // delegate reference explicitly before tearing down.
  if (scheduler_) {
    scheduler_->setDelegate(nullptr);
  }
  // EXIT RACE (see ExitRaceProbe above): stop NEW ticks from reaching the
  // event-timing delegate, then wait out the tick that may already hold it.
  // The barrier runs on the JS thread after the current tick, so when it
  // fires nothing can still be inside the delegate. Bounded: a wedged JS
  // thread must not hang quit.
  if (runtimeScheduler_) {
    runtimeScheduler_->setEventTimingDelegate(nullptr);
    auto drained = std::make_shared<std::promise<void>>();
    auto done = drained->get_future();
    runtimeScheduler_->scheduleWork(
        [drained](facebook::jsi::Runtime&) { drained->set_value(); });
    if (done.wait_for(std::chrono::seconds(3)) != std::future_status::ready) {
      std::fprintf(stderr, "rn-impeller: WARN: JS thread did not drain before "
                           "Scheduler teardown (3 s)\n");
    }
  }
  scheduler_.reset();
  gSchedulerTornDown = true;
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

  rni::modal::SetScreenSize(pointWidth, pointHeight);
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

  rni::modal::SetScreenSize(pointWidth, pointHeight);
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
  // ENG-15: a release INSIDE a <Switch> toggles it, like UISwitch's
  // touch-up-inside. "Inside" is a fresh hit test at the release point, so a
  // captured press dragged off the switch and released elsewhere cancels.
  // Every release path (headless --tap, the windowed capture) comes through
  // here, so the toggle cannot differ between them.
  if (phase == TouchPhase::Up && sceneGraph_->isSwitchTag(target) &&
      sceneGraph_->hitTest(x, y) == target) {
    toggleSwitch((std::int32_t)target);
  }
  return (int)target;
}

// ENG-15. Flip the Switch's painted value, then tell JS through the Switch's
// own generated emitter: SwitchEventEmitter::onChange({value, target}), the
// payload Switch.js's handleChange reads (event.nativeEvent.value). JS then
// re-commits `value` (controlled) or, when it keeps its old value, sends the
// setValue view command back (runCommand), as on iOS.
int FabricHost::toggleSwitch(std::int32_t tag) {
  if (!sceneGraph_ || !runtimeScheduler_) return -1;
  const int v = sceneGraph_->toggleSwitch((react::Tag)tag);
  if (v < 0) return -1;
  auto sw = std::dynamic_pointer_cast<const react::SwitchEventEmitter>(
      sceneGraph_->eventEmitterFor((react::Tag)tag));
  printf("rn-impeller: switch_toggle tag=%d value=%d emitter=%d\n", (int)tag, v,
         sw ? 1 : 0);
  fflush(stdout);
  if (sw) {
    react::SwitchEventEmitter::OnChange ev{v == 1, (int)tag};
    runtimeScheduler_->scheduleWork(
        [sw, ev](facebook::jsi::Runtime&) { sw->onChange(ev); });
  }
  return v;
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

  emitScroll((int)res.tag, res.offsetX, res.offsetY, res.contentWidth,
             res.contentHeight, res.containerWidth, res.containerHeight);
  return (int)res.tag;
}

// item 7: shared by wheel scrolling and the scrollTo/scrollToEnd commands.
void FabricHost::emitScroll(int tag, float offsetX, float offsetY,
                            float contentW, float contentH, float containerW,
                            float containerH) {
  auto scrollEmitter = std::dynamic_pointer_cast<const react::ScrollViewEventEmitter>(
      sceneGraph_->eventEmitterFor((react::Tag)tag));
  if (!scrollEmitter) return;
  react::ScrollEvent event{};
  // Both axes reported: a horizontal list drives contentOffset.x, and a JS
  // handler reading nativeEvent.contentOffset.x for a sticky column header or a
  // paged carousel index would otherwise always read zero while the pixels slid.
  event.contentOffset = {(react::Float)offsetX, (react::Float)offsetY};
  event.contentSize = {(react::Float)contentW, (react::Float)contentH};
  event.containerSize = {(react::Float)containerW, (react::Float)containerH};
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

// desktop-input-gap item 6. W3C pointer events for ANY mouse button, on the
// hit-tested tag (Fabric bubbles them to ancestors). down/up -> onPointerDown/
// onPointerUp. A release over the SAME tag as its press is a click: onClick
// for the left button (detail = click count), and an `auxClick` event for the
// others (registered as topAuxClick by the BaseViewConfig shim, matching
// react-native-macos/-windows). No touch is involved: Pressable's onPress and
// TextInput focus stay on the left button's own touch path in main.cpp.
int FabricHost::dispatchPointerButton(float x, float y, bool down, int button,
                                      int buttons, int clickCount, bool shift,
                                      bool ctrl, bool alt, bool meta) {
  if (!sceneGraph_ || !runtimeScheduler_) return 0;
  const react::Tag tag = sceneGraph_->hitTest(x, y);
  if (button < 0 || button > 4) return 0;
  const int pressTag = pointerPressTag_[button];
  if (down) pointerPressTag_[button] = (int)tag;
  if (!down) pointerPressTag_[button] = 0;
  if (tag == 0) return 0;
  auto touchEmitter = std::dynamic_pointer_cast<const react::TouchEventEmitter>(
      sceneGraph_->eventEmitterFor(tag));
  if (!touchEmitter) return 0;

  react::PointerEvent event{};
  event.pointerId = 1;
  event.pointerType = "mouse";
  event.isPrimary = true;
  event.clientPoint = {x, y};
  event.screenPoint = {x, y};
  event.offsetPoint = {x, y};
  event.pressure = buttons != 0 ? 0.5f : 0.0f;
  event.width = 1.0f;
  event.height = 1.0f;
  event.button = button;
  event.buttons = buttons;
  event.detail = clickCount;
  event.shiftKey = shift;
  event.ctrlKey = ctrl;
  event.altKey = alt;
  event.metaKey = meta;

  const bool isClick = !down && pressTag == (int)tag;
  printf("rn-impeller: pointer %s tag=%d button=%d buttons=%d detail=%d "
         "mods=shift:%d,ctrl:%d,alt:%d,meta:%d%s\n",
         down ? "down" : "up", (int)tag, button, buttons, clickCount,
         shift ? 1 : 0, ctrl ? 1 : 0, alt ? 1 : 0, meta ? 1 : 0,
         isClick ? (button == 0 ? " click" : " auxclick") : "");
  fflush(stdout);
  runtimeScheduler_->scheduleWork(
      [touchEmitter, event, down, isClick, button](facebook::jsi::Runtime&) {
        if (down) {
          touchEmitter->onPointerDown(event);
          return;
        }
        touchEmitter->onPointerUp(event);
        if (!isClick) return;
        if (button == 0) {
          touchEmitter->onClick(event);
        } else {
          touchEmitter->dispatchEvent(
              "auxClick", std::make_shared<react::PointerEvent>(event),
              react::RawEvent::Category::Discrete);
        }
      });
  return (int)tag;
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
int FabricHost::focusTextInputAt(float x, float y, int clickCount,
                                 bool shift) {
  if (!sceneGraph_) return 0;
  // item 11: a click moves keyboard focus away from a Tab-focused View.
  blurFocusedView();
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
    dragTag_ = 0;
    return 0;
  }
  // item 3: clicking the field that ALREADY has focus must not re-seed the
  // edit buffer from the controlled value (that would drop uncommitted typing
  // on an uncontrolled field) and must not re-fire onFocus. It only moves the
  // caret.
  const react::Tag prevField = sceneGraph_->focusedTextInput();
  const bool alreadyFocused = (prevField == target);
  // item 11: clicking from one field into another blurs the old one (it used
  // to switch silently, with no onBlur).
  if (prevField != 0 && !alreadyFocused) emitTextInputFocusEvent(prevField, false);
  if (!alreadyFocused) sceneGraph_->setTextInputFocus(target);
  auto emitter = sceneGraph_->eventEmitterFor(target);
  auto te =
      std::dynamic_pointer_cast<const react::TextInputEventEmitter>(emitter);
  if (te && !alreadyFocused) {
    react::TextInputEventEmitter::Metrics m{};
    m.text = sceneGraph_->textInputValueFor(target);
    m.eventCount = ++tiEventCount_;
    runtimeScheduler_->scheduleWork(
        [te, m](facebook::jsi::Runtime&) { te->onFocus(m); });
    emitContentSizeIfChanged((int)target);  // ENG-24: the starting size
  }
  // item 3: click-to-caret. The caret goes to the codepoint boundary nearest
  // the click x, measured by SceneGraph with the painter's own text layout.
  // Before item 3 a click always left the caret at END (setTextInputFocus's
  // seed) no matter where in the text the user clicked.
  const std::string value = sceneGraph_->textInputValueFor(target);
  const size_t hitPos = sceneGraph_->caretIndexForClick(target, x, y);
  // item 4b: mouse selection. clickCount 2 selects the word under the click,
  // 3 (or more) the whole line (single-line field: all text). Shift+click on
  // the already-focused field extends the selection from its anchor. Every
  // press arms a drag: moves while the button is held extend from dragAnchor_.
  size_t anchor = hitPos;
  size_t caret = hitPos;
  dragUnit_ = 1;
  if (clickCount >= 3) {
    anchor = 0;
    caret = value.size();
    dragUnit_ = 3;
  } else if (clickCount == 2) {
    anchor = Utf8WordStartAt(value, hitPos);
    caret = Utf8WordEndAt(value, hitPos);
    dragUnit_ = 2;
  } else if (shift && alreadyFocused) {
    anchor = sceneGraph_->textInputSelectionAnchorFor(target);
  }
  dragTag_ = target;
  dragAnchorLo_ = std::min(anchor, caret);
  dragAnchorHi_ = std::max(anchor, caret);
  if (anchor == caret) {
    sceneGraph_->setTextInputEdit(target, value, caret);
  } else {
    sceneGraph_->setTextInputSelection(target, value, anchor, caret);
  }
  printf("rn-impeller: selection tag=%d anchor=%zu caret=%zu clicks=%d\n",
         (int)target, anchor, caret, clickCount);
  const std::string report = sceneGraph_->glyphBoundaryReportFor(target);
  if (!report.empty()) printf("%s\n", report.c_str());
  printf("rn-impeller: caret tag=%d pos=%zu text=%s\n", (int)target, caret,
         EscapeForLog(value).c_str());
  fflush(stdout);
  if (te) {
    react::TextInputEventEmitter::Metrics m{};
    m.text = value;
    m.eventCount = ++tiEventCount_;
    const int lo = (int)Utf8OffsetToUtf16Units(value, std::min(anchor, caret));
    const int hi = (int)Utf8OffsetToUtf16Units(value, std::max(anchor, caret));
    m.selectionRange.location = lo;
    m.selectionRange.length = hi - lo;
    runtimeScheduler_->scheduleWork(
        [te, m](facebook::jsi::Runtime&) { te->onSelectionChange(m); });
  }
  return (int)target;
}

// item 4b. A cursor move while the left button is held after a press that
// landed in a TextInput: extend the selection from the press's anchor, in the
// unit the press chose (1 char, 2 word, 3 line). Returns true when it handled
// the move (the caller skips hover dispatch).
bool FabricHost::dragTextSelection(float x, float y) {
  // P1 item 15: a held press that began on a selectable <Text> extends that
  // paragraph's selection from the press point. The point is mapped through
  // the paragraph's OWN layout even when the cursor leaves its box (a drag
  // past the end selects to the end), so no re-hit-test happens here.
  if (sceneGraph_ && textDragTag_ != 0) {
    const react::Tag tag = (react::Tag)textDragTag_;
    const size_t caret = sceneGraph_->textOffsetAt(tag, x, y);
    sceneGraph_->setTextSelection(tag, textDragAnchor_, caret);
    printf("rn-impeller: text_selection tag=%d anchor=%zu caret=%zu drag=1\n",
           (int)tag, textDragAnchor_, caret);
    fflush(stdout);
    return true;
  }
  if (!sceneGraph_ || !runtimeScheduler_ || dragTag_ == 0) return false;
  const react::Tag tag = (react::Tag)dragTag_;
  if (sceneGraph_->focusedTextInput() != tag) {
    dragTag_ = 0;
    return false;
  }
  const std::string value = sceneGraph_->textInputValueFor(tag);
  const size_t hitPos = sceneGraph_->caretIndexForClick(tag, x, y);
  size_t anchor = dragAnchorLo_;
  size_t caret = hitPos;
  if (dragUnit_ >= 3) {
    anchor = 0;
    caret = value.size();
  } else if (dragUnit_ == 2) {
    // Word drag: grow by whole words, keeping the originally clicked word.
    if (hitPos < dragAnchorLo_) {
      anchor = dragAnchorHi_;
      caret = Utf8WordStartAt(value, hitPos);
    } else {
      anchor = dragAnchorLo_;
      caret = std::max(dragAnchorHi_, Utf8WordEndAt(value, hitPos));
    }
  } else if (hitPos < dragAnchorLo_) {
    anchor = dragAnchorHi_;
  }
  if (anchor > value.size()) anchor = value.size();
  if (caret > value.size()) caret = value.size();
  if (anchor == sceneGraph_->textInputSelectionAnchorFor(tag) &&
      caret == sceneGraph_->textInputCaretFor(tag)) {
    return true;  // no change: stay quiet, one line per real change
  }
  if (anchor == caret) {
    sceneGraph_->setTextInputEdit(tag, value, caret);
  } else {
    sceneGraph_->setTextInputSelection(tag, value, anchor, caret);
  }
  printf("rn-impeller: selection tag=%d anchor=%zu caret=%zu drag=1\n",
         (int)tag, anchor, caret);
  fflush(stdout);
  auto te = std::dynamic_pointer_cast<const react::TextInputEventEmitter>(
      sceneGraph_->eventEmitterFor(tag));
  if (te) {
    react::TextInputEventEmitter::Metrics m{};
    m.text = value;
    m.eventCount = ++tiEventCount_;
    const int lo = (int)Utf8OffsetToUtf16Units(value, std::min(anchor, caret));
    const int hi = (int)Utf8OffsetToUtf16Units(value, std::max(anchor, caret));
    m.selectionRange.location = lo;
    m.selectionRange.length = hi - lo;
    runtimeScheduler_->scheduleWork(
        [te, m](facebook::jsi::Runtime&) { te->onSelectionChange(m); });
  }
  return true;
}

void FabricHost::endTextSelectionDrag() {
  dragTag_ = 0;
  textDragTag_ = 0;  // P1 item 15: the selection itself stays until a press
}

// P1 item 15. See the header. A press that does not land on selectable text
// clears any paragraph selection, as a click elsewhere does on every desktop.
int FabricHost::beginTextSelection(float x, float y, int clickCount) {
  if (!sceneGraph_) return 0;
  textDragTag_ = 0;
  const react::Tag tag = sceneGraph_->selectableTextAt(x, y);
  if (tag == 0) {
    sceneGraph_->clearTextSelection();
    return 0;
  }
  const std::string shown = sceneGraph_->selectableTextFor(tag);
  const size_t hit = sceneGraph_->textOffsetAt(tag, x, y);
  size_t anchor = hit, caret = hit;
  if (clickCount >= 3) {
    anchor = 0;
    caret = shown.size();
  } else if (clickCount == 2) {
    anchor = Utf8WordStartAt(shown, hit);
    caret = Utf8WordEndAt(shown, hit);
  }
  sceneGraph_->setTextSelection(tag, anchor, caret);
  // A word/line press drags from the start of what it selected.
  textDragTag_ = (int)tag;
  textDragAnchor_ = anchor;
  printf("rn-impeller: text_selection tag=%d anchor=%zu caret=%zu clicks=%d\n",
         (int)tag, anchor, caret, clickCount);
  fflush(stdout);
  return (int)tag;
}

bool FabricHost::copyTextSelection() {
  if (!sceneGraph_ || sceneGraph_->textSelectionTag() == 0) return false;
  const std::string selected = sceneGraph_->selectedText();
  if (selected.empty()) return false;
  if (clipboardSet_) clipboardSet_(selected);
  printf("rn-impeller: clipboard op=copy-text bytes=%zu text=%s\n",
         selected.size(), EscapeForLog(selected).c_str());
  fflush(stdout);
  return true;
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
int FabricHost::dispatchKey(KeyAction action, unsigned int codepoint,
                            bool extendSelection) {
  if (!sceneGraph_ || !runtimeScheduler_) return 0;
  react::Tag tag = sceneGraph_->focusedTextInput();
  if (tag == 0) return 0;

  auto emitter = sceneGraph_->eventEmitterFor(tag);
  auto te =
      std::dynamic_pointer_cast<const react::TextInputEventEmitter>(emitter);
  if (!te) return 0;

  bool insertNewline = false;  // ENG-24: set only by the multiline Enter path
  if (action == KeyAction::Submit || action == KeyAction::Newline) {
    // ENG-24: Enter follows RN's submitBehavior (resolved by
    // BaseTextInputProps::getNonDefaultSubmitBehavior: 1 submit,
    // 2 blurAndSubmit, 3 newline). In a MULTILINE field Shift+Enter (the
    // Newline action) always breaks the line, the desktop chat convention
    // and react-native-macos's default (only a bare Enter is a submit key).
    // A single-line field has no line to break: Enter and Shift+Enter both
    // submit, and buffer and caret are untouched.
    bool multiline = false;
    int submitBehavior = 2;
    sceneGraph_->textInputKeyTraits(tag, &multiline, &submitBehavior);
    const bool newline =
        multiline && (action == KeyAction::Newline || submitBehavior == 3);
    if (!newline) {
      react::TextInputEventEmitter::Metrics m{};
      m.text = sceneGraph_->textInputValueFor(tag);
      m.eventCount = ++tiEventCount_;
      runtimeScheduler_->scheduleWork(
          [te, m](facebook::jsi::Runtime&) { te->onSubmitEditing(m); });
      const bool blur = submitBehavior == 2;
      printf("rn-impeller: ti_submit tag=%d behavior=%d blur=%d\n", (int)tag,
             submitBehavior, (int)blur);
      fflush(stdout);
      if (blur) {
        // blurAndSubmit: onSubmitEditing first, then the field lets go.
        emitTextInputFocusEvent((int)tag, false);
        sceneGraph_->clearTextInputFocus();
        dragTag_ = 0;
      }
      return (int)tag;
    }
    // A line break, inserted at the caret like a typed character.
    action = KeyAction::InsertChar;
    insertNewline = true;
  }

  std::string value = sceneGraph_->textInputValueFor(tag);
  size_t caret = sceneGraph_->textInputCaretFor(tag);
  if (caret > value.size()) caret = value.size();  // defensive clamp
  // item 4a: the selection's fixed end. anchor == caret means no selection.
  size_t anchor = sceneGraph_->textInputSelectionAnchorFor(tag);
  if (anchor > value.size()) anchor = value.size();
  const size_t selLo = std::min(anchor, caret);
  const size_t selHi = std::max(anchor, caret);
  const bool hasSel = selLo != selHi;
  const bool isMove =
      action == KeyAction::MoveLeft || action == KeyAction::MoveRight ||
      action == KeyAction::MoveWordLeft || action == KeyAction::MoveWordRight ||
      action == KeyAction::MoveHome || action == KeyAction::MoveEnd ||
      action == KeyAction::MoveUp || action == KeyAction::MoveDown;
  // Editing with a selection first removes the selected range; the edit then
  // happens at its start (typing replaces, Backspace/Delete delete only it).
  bool textChanged = false;
  bool consumed = false;
  if (hasSel && (action == KeyAction::InsertChar ||
                 action == KeyAction::Backspace ||
                 action == KeyAction::DeleteForward)) {
    value.erase(selLo, selHi - selLo);
    caret = selLo;
    textChanged = true;
    consumed = action != KeyAction::InsertChar;
  }
  // A plain (unshifted) Left/Right with a selection collapses it to its
  // near edge instead of moving one more step (macOS + Windows behaviour).
  if (hasSel && !extendSelection &&
      (action == KeyAction::MoveLeft || action == KeyAction::MoveRight)) {
    caret = action == KeyAction::MoveLeft ? selLo : selHi;
    consumed = true;
  }
  if (action == KeyAction::SelectAll) {
    anchor = 0;
    caret = value.size();
    consumed = true;
  }
  // item 5. Copy/Cut/Paste are each fully handled here, before the main
  // switch, because none of them fit its action-at-caret shape: Copy reads
  // without touching the buffer at all, Cut's erase mirrors the
  // InsertChar/Backspace/DeleteForward selection-erase above but writes the
  // clipboard FIRST, and Paste's inserted text is multiple bytes decided at
  // dispatch time (the clipboard content), not a single decoded codepoint.
  if ((action == KeyAction::Copy || action == KeyAction::Cut) &&
      sceneGraph_->isSecureTextInput(tag)) {
    // Style audit item 11: a secureTextEntry field never puts its value on
    // the clipboard (UITextField and NSSecureTextField both refuse Copy and
    // Cut). The shortcut is consumed so it does nothing else either.
    printf("rn-impeller: clipboard op=refused-secure\n");
    fflush(stdout);
    consumed = true;
  } else if (action == KeyAction::Copy || action == KeyAction::Cut) {
    // Empty selection: no clipboard write, no buffer change, full stop. A
    // Cmd/Ctrl+C with the caret merely sitting somewhere (no selection) must
    // leave whatever was already on the clipboard untouched -- the Copy
    // keeps the PREVIOUS content exactly as if the shortcut were never
    // pressed, which is what arm (f) in the gate asserts.
    if (!hasSel) {
      consumed = true;
    } else {
      const std::string selected = value.substr(selLo, selHi - selLo);
      if (clipboardSet_) clipboardSet_(selected);
      printf("rn-impeller: clipboard op=%s bytes=%zu\n",
             action == KeyAction::Copy ? "copy" : "cut", selected.size());
      fflush(stdout);
      if (action == KeyAction::Cut) {
        value.erase(selLo, selHi - selLo);
        caret = selLo;
        textChanged = true;
      }
      consumed = true;
    }
  } else if (action == KeyAction::Paste) {
    const std::string raw = clipboardGet_ ? clipboardGet_() : std::string();
    const std::string flattened = FlattenNewlinesForSingleLine(raw);
    if (hasSel) {
      value.erase(selLo, selHi - selLo);
      caret = selLo;
    }
    value.insert(caret, flattened);
    caret += flattened.size();
    textChanged = true;
    printf("rn-impeller: clipboard op=paste bytes=%zu\n", flattened.size());
    fflush(stdout);
    consumed = true;
  }
  if (!consumed) switch (action) {
    case KeyAction::InsertChar: {
      // Any Unicode scalar value >= 0x20 except 0x7F (DEL) and surrogate
      // halves -- see Utf8EncodeAppend's header. Inserted AT THE CARET, not
      // appended at the end.
      std::string encoded;
      if (insertNewline) {
        encoded = "\n";  // ENG-24: the multiline Enter path
      } else if (!Utf8EncodeAppend(&encoded, codepoint)) {
        encoded.clear();
      }
      if (!encoded.empty()) {
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
    case KeyAction::MoveUp:
    case KeyAction::MoveDown: {
      // ENG-25: one wrapped line up/down, at the column the run of vertical
      // moves started from (kept only while the caret is where the last
      // vertical move left it).
      float goal = ((int)tag == vertGoalTag_ && caret == vertGoalCaret_)
                       ? vertGoalX_
                       : -1.0f;
      caret = sceneGraph_->textInputVerticalMove(
          tag, caret, action == KeyAction::MoveUp ? -1 : 1, &goal);
      vertGoalTag_ = (int)tag;
      vertGoalCaret_ = caret;
      vertGoalX_ = goal;
      break;
    }
    case KeyAction::Submit:
    case KeyAction::Newline:
    case KeyAction::SelectAll:
    case KeyAction::Copy:
    case KeyAction::Cut:
    case KeyAction::Paste:
      break;  // handled above; unreachable here
  }

  // item 4a: the anchor stays put only for a Shift+move and for SelectAll;
  // every other action collapses the selection onto the new caret.
  const bool keepAnchor =
      (isMove && extendSelection) || action == KeyAction::SelectAll;
  if (!keepAnchor) anchor = caret;

  // Apply to the paint buffer first so a paint scheduled by the JS re-render
  // below never briefly shows the pre-edit string or the caret at its old
  // index. Both setters clamp to value.size() defensively too.
  if (anchor == caret) {
    sceneGraph_->setTextInputEdit(tag, value, caret);
  } else {
    sceneGraph_->setTextInputSelection(tag, value, anchor, caret);
  }
  printf("rn-impeller: caret tag=%d pos=%zu text=%s\n", (int)tag, caret,
         EscapeForLog(value).c_str());
  printf("rn-impeller: selection tag=%d anchor=%zu caret=%zu\n", (int)tag,
         anchor, caret);
  fflush(stdout);

  react::TextInputEventEmitter::Metrics m{};
  m.text = value;
  m.eventCount = ++tiEventCount_;
  if (textChanged) lastChangeEventCount_[(int)tag] = m.eventCount;  // item 7
  // UTF-16 code units, per RN's own selectionRange convention -- NOT the
  // UTF-8 byte offset the engine stores internally.
  // item 4a: ordered {start,end}; length 0 when collapsed.
  const int loUnits =
      (int)Utf8OffsetToUtf16Units(value, std::min(anchor, caret));
  const int hiUnits =
      (int)Utf8OffsetToUtf16Units(value, std::max(anchor, caret));
  m.selectionRange.location = loUnits;
  m.selectionRange.length = hiUnits - loUnits;
  runtimeScheduler_->scheduleWork([te, m, textChanged](facebook::jsi::Runtime&) {
    // onChange is what RN's TextInput.js turns into onChangeText(text): its
    // _onChange reads nativeEvent.text and calls props.onChangeText. Fired
    // ONLY when the text changed -- see the header's effect (3).
    if (textChanged) te->onChange(m);
    // onSelectionChange fires unconditionally: the caret moved (or stayed,
    // for a no-op edit at a buffer edge) either way.
    te->onSelectionChange(m);
  });
  if (textChanged) emitContentSizeIfChanged((int)tag);  // ENG-24
  return (int)tag;
}

// ENG-24. onContentSizeChange: RN's TextInputEventEmitter payload
// ({contentSize: {width, height}, target}). Sent only on a change, the way
// UITextView's contentSize observer fires, so a growing composer gets one
// event per new line rather than one per keystroke.
void FabricHost::emitContentSizeIfChanged(int tag) {
  if (!sceneGraph_ || !runtimeScheduler_) return;
  float cw = 0.0f, ch = 0.0f;
  if (!sceneGraph_->textInputContentSize(tag, &cw, &ch)) return;
  auto it = lastContentSize_.find(tag);
  if (it != lastContentSize_.end() && std::fabs(it->second.first - cw) < 0.5f &&
      std::fabs(it->second.second - ch) < 0.5f) {
    return;
  }
  lastContentSize_[tag] = {cw, ch};
  auto te = std::dynamic_pointer_cast<const react::TextInputEventEmitter>(
      sceneGraph_->eventEmitterFor(tag));
  if (!te) return;
  react::TextInputEventEmitter::Metrics m{};
  m.text = sceneGraph_->textInputValueFor(tag);
  m.contentSize = react::Size{cw, ch};
  m.eventCount = tiEventCount_;
  printf("rn-impeller: ti_content_size tag=%d w=%.1f h=%.1f\n", tag, cw, ch);
  fflush(stdout);
  runtimeScheduler_->scheduleWork(
      [te, m](facebook::jsi::Runtime&) { te->onContentSizeChange(m); });
}

// desktop-input-gap P0 item 1. Full keyboard forwarding to JS -- see the
// header for the two-channel design (TextInput onKeyPress + a generic
// keyDown/keyUp dispatchEvent) and why RN 0.86's C++ BaseViewEventEmitter
// cannot carry a real onKeyDown method.
int FabricHost::dispatchKeyEvent(const std::string& key,
                                 const std::string& code, KeyEventPhase phase,
                                 const KeyModifiers& mods) {
  if (!sceneGraph_ || !runtimeScheduler_) return 0;
  // A22: Escape asks the topmost visible modal to close (Android's back
  // button, iOS's swipe-dismiss); the modal consumes the key.
  if (key == "Escape" && phase == KeyEventPhase::Down) {
    react::EventEmitter::Shared emitter;
    if (const react::Tag modal = sceneGraph_->topModal(&emitter)) {
      if (auto m = std::dynamic_pointer_cast<const react::ModalHostViewEventEmitter>(emitter))
        m->onRequestClose({});
      std::printf("[modal] request_close tag=%d\n", modal);
      std::fflush(stdout);
      return modal;
    }
  }
  // Focused field first; fall back to the surface root so a key event
  // always has SOMEWHERE to land rather than being silently swallowed the
  // instant nothing has focus -- the ask explicitly requires this fallback.
  react::Tag target = sceneGraph_->focusedTextInput();
  // item 11: a focused (non-TextInput) View receives key events.
  if (target == 0) target = sceneGraph_->focusedView();
  if (target == 0) target = sceneGraph_->rootTag();
  if (target == 0) return 0;

  auto emitter = sceneGraph_->eventEmitterFor(target);
  if (!emitter) return 0;

  // item 11: plain Tab / Shift+Tab move keyboard focus AFTER this key's own
  // events reach the element that had focus (react-native-windows order:
  // keyDown to the focused element first, then navigation). Ctrl/Alt/Cmd+Tab
  // are app/OS shortcuts and never navigate.
  const bool tabNav = key == "Tab" && phase != KeyEventPhase::Up &&
                      !mods.ctrl && !mods.alt && !mods.meta;

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
    const bool selectAllMod = mods.meta;
#else
    const bool wordMod = mods.ctrl;
    const bool selectAllMod = mods.ctrl;
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
    } else if ((key == "ArrowUp" || key == "ArrowDown") &&
               sceneGraph_->isMultilineTextInput(sceneGraph_->focusedTextInput())) {
      // ENG-25: a multiline field moves the caret one WRAPPED line. A
      // single-line field keeps its old behaviour (no caret move).
      caretAction = key == "ArrowUp" ? KeyAction::MoveUp : KeyAction::MoveDown;
    } else if ((key == "c" || key == "C") && selectAllMod && !mods.alt) {
      // item 5. Copy = selectAllMod+c (Cmd on darwin, Ctrl elsewhere).
      caretAction = KeyAction::Copy;
    } else if ((key == "x" || key == "X") && selectAllMod && !mods.alt) {
      // item 5. Cut = selectAllMod+x.
      caretAction = KeyAction::Cut;
    } else if ((key == "v" || key == "V") && selectAllMod && !mods.alt) {
      // item 5. Paste = selectAllMod+v.
      caretAction = KeyAction::Paste;
#if !defined(__APPLE__)
    } else if (key == "Insert" && mods.ctrl && !mods.alt) {
      // item 5. Non-apple extra: Ctrl+Insert copies.
      caretAction = KeyAction::Copy;
    } else if (key == "Insert" && mods.shift && !mods.alt) {
      // item 5. Non-apple extra: Shift+Insert pastes.
      caretAction = KeyAction::Paste;
    } else if (key == "Delete" && mods.shift && !mods.alt) {
      // item 5. Non-apple extra: Shift+Delete cuts. Checked BEFORE the plain
      // Delete->DeleteForward case below so a Shift+Delete does not fall
      // through to forward-delete instead.
      caretAction = KeyAction::Cut;
#endif
    } else if (key == "Delete") {
      caretAction = KeyAction::DeleteForward;
    } else if ((key == "a" || key == "A") && selectAllMod && !mods.alt) {
      // item 4a: select all. Cmd+A on darwin, Ctrl+A elsewhere.
      caretAction = KeyAction::SelectAll;
    } else {
      isCaretKey = false;
    }
    // item 4a: Shift extends the selection for caret moves.
    if (isCaretKey) dispatchKey(caretAction, 0, mods.shift);
  }

  // P1 item 15: Copy with NO focused field copies a selectable <Text>'s
  // selection (Cmd+C on darwin, Ctrl+C / Ctrl+Insert elsewhere, the same
  // chords the field path uses). A focused field always wins: it owns the
  // keyboard, and a stale paragraph selection must not hijack its Copy.
  if (sceneGraph_->focusedTextInput() == 0 && phase != KeyEventPhase::Up) {
#if defined(__APPLE__)
    const bool copyChord = (key == "c" || key == "C") && mods.meta && !mods.alt;
#else
    const bool copyChord = ((key == "c" || key == "C") && mods.ctrl && !mods.alt) ||
                           (key == "Insert" && mods.ctrl && !mods.alt);
#endif
    if (copyChord) copyTextSelection();
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
      // ENG-24: RN core's KeyPressMetrics carries only text + eventCount, so
      // nativeEvent.shiftKey was undefined and a composer could not tell
      // Shift+Enter from Enter. Dispatch the same "keyPress" event RN's
      // onKeyPress does (its key derivation, reproduced by `text` above, is
      // our W3C key byte for byte) with the modifier flags added, the shape
      // react-native-macos / -windows send.
      (void)text;
      const int eventCount = ++tiEventCount_;
      runtimeScheduler_->scheduleWork(
          [te, key, mods, eventCount](facebook::jsi::Runtime&) {
            te->dispatchEvent(
                "keyPress",
                [key, mods, eventCount](facebook::jsi::Runtime& runtime) {
                  auto payload = facebook::jsi::Object(runtime);
                  payload.setProperty(runtime, "eventCount", eventCount);
                  payload.setProperty(
                      runtime, "key",
                      facebook::jsi::String::createFromUtf8(runtime, key));
                  payload.setProperty(runtime, "shiftKey", mods.shift);
                  payload.setProperty(runtime, "ctrlKey", mods.ctrl);
                  payload.setProperty(runtime, "altKey", mods.alt);
                  payload.setProperty(runtime, "metaKey", mods.meta);
                  return facebook::jsi::Value(std::move(payload));
                });
          });
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

  if (tabNav) moveFocus(!mods.shift);
  return (int)target;
}

// item 7. View commands.
void FabricHost::postCommand(ViewCommand cmd) {
  bool queued = false;
  std::function<void()> wake;
  {
    std::lock_guard<std::mutex> lock(mainMutex_);
    if (mainQueueEnabled_) {
      mainQueue_.push_back(std::move(cmd));
      wake = mainWake_;
      queued = true;
    }
  }
  if (queued) {
    if (wake) wake();
    return;
  }
  runCommand(cmd);  // headless: there is no separate main thread to protect
}

void FabricHost::enableMainQueue(std::function<void()> wake) {
  std::lock_guard<std::mutex> lock(mainMutex_);
  mainQueueEnabled_ = true;
  mainWake_ = std::move(wake);
}

void FabricHost::drainMain() {
  std::vector<ViewCommand> batch;
  {
    std::lock_guard<std::mutex> lock(mainMutex_);
    batch.swap(mainQueue_);
  }
  for (const auto& c : batch) runCommand(c);
}

void FabricHost::runCommand(const ViewCommand& cmd) {
  if (!sceneGraph_ || !runtimeScheduler_) return;
  const react::Tag tag = (react::Tag)cmd.tag;
  printf("rn-impeller: command tag=%d name=%s nums=%zu text=%d\n", cmd.tag,
         cmd.name.c_str(), cmd.nums.size(), cmd.hasText ? 1 : 0);
  fflush(stdout);

  if (cmd.name == "scrollTo" || cmd.name == "scrollToEnd") {
    // scrollTo(x, y, animated) / scrollToEnd(animated). An animated scroll
    // jumps straight to the target (there is no scroll animation driver yet),
    // which is what RN does when animations are disabled.
    const bool toEnd = cmd.name == "scrollToEnd";
    const float x = cmd.nums.size() > 0 ? (float)cmd.nums[0] : 0.0f;
    const float y = cmd.nums.size() > 1 ? (float)cmd.nums[1] : 0.0f;
    const auto r = sceneGraph_->scrollTo(tag, x, y, toEnd);
    if (r.tag == 0) return;
    printf("rn-impeller: scroll_command tag=%d x=%.1f y=%.1f\n", cmd.tag,
           r.offsetX, r.offsetY);
    fflush(stdout);
    emitScroll(cmd.tag, r.offsetX, r.offsetY, r.contentWidth, r.contentHeight,
               r.containerWidth, r.containerHeight);
    return;
  }
  if (cmd.name == "flashScrollIndicators" || cmd.name == "zoomToRect") {
    return;  // no scroll indicators / zoom on this platform: honest no-op
  }

  // ENG-15. SwitchNativeComponent's iOS command: Switch.js sends it from a
  // layout effect when JS keeps a value different from the one native just
  // toggled to (an uncontrolled or refusing parent), so the switch snaps back.
  if (cmd.name == "setValue") {
    if (cmd.bools.empty()) return;
    const int v = sceneGraph_->setSwitchValue(tag, cmd.bools[0]);
    printf("rn-impeller: switch_set tag=%d value=%d\n", cmd.tag, v);
    fflush(stdout);
    return;
  }

  if (cmd.name == "focus") {
    if (!sceneGraph_->isTextInputTag(tag)) return;
    const react::Tag prev = sceneGraph_->focusedTextInput();
    if (prev == tag) return;
    if (prev != 0) {
      emitTextInputFocusEvent(prev, false);
      sceneGraph_->clearTextInputFocus();
      dragTag_ = 0;
    }
    blurFocusedView();
    sceneGraph_->setTextInputFocus(tag);  // caret at the end, like iOS
    emitTextInputFocusEvent(tag, true);
    emitContentSizeIfChanged(tag);  // ENG-24
    return;
  }
  if (cmd.name == "blur") {
    if (sceneGraph_->focusedTextInput() != tag) return;
    emitTextInputFocusEvent(tag, false);
    sceneGraph_->clearTextInputFocus();
    dragTag_ = 0;
    return;
  }

  if (cmd.name == "setTextAndSelection") {
    // (mostRecentEventCount, value | null, start, end); start/end -1 = keep.
    // nums holds [eventCount, start, end] (the value is a string or null).
    if (cmd.nums.size() < 3) return;
    const int eventCount = (int)cmd.nums[0];
    const int startU16 = (int)cmd.nums[1];
    const int endU16 = (int)cmd.nums[2];
    const bool focused = sceneGraph_->focusedTextInput() == tag;
    std::string value = sceneGraph_->textInputValueFor(tag);
    bool textChanged = false;
    auto lastIt = lastChangeEventCount_.find(cmd.tag);
    const bool stale =
        lastIt != lastChangeEventCount_.end() && eventCount < lastIt->second;
    if (cmd.hasText && !stale && cmd.text != value) {
      value = cmd.text;
      textChanged = true;
    }
    if (!focused) {
      // Not being edited: only the displayed value changes; the selection
      // applies the next time the field takes focus (iOS behaviour).
      if (textChanged) sceneGraph_->setTextInputValue(tag, value);
      printf("rn-impeller: settext_unfocused tag=%d text=%s\n", cmd.tag,
             EscapeForLog(value).c_str());
      fflush(stdout);
      if (textChanged) emitContentSizeIfChanged(cmd.tag);  // ENG-24
      return;
    }
    size_t anchor = sceneGraph_->textInputSelectionAnchorFor(tag);
    size_t caret = sceneGraph_->textInputCaretFor(tag);
    if (textChanged) anchor = caret = value.size();
    if (startU16 >= 0 && endU16 >= 0) {
      anchor = Utf16UnitsToUtf8Offset(value, (size_t)startU16);
      caret = Utf16UnitsToUtf8Offset(value, (size_t)endU16);
    }
    if (anchor > value.size()) anchor = value.size();
    if (caret > value.size()) caret = value.size();
    if (anchor == caret) {
      sceneGraph_->setTextInputEdit(tag, value, caret);
    } else {
      sceneGraph_->setTextInputSelection(tag, value, anchor, caret);
    }
    printf("rn-impeller: caret tag=%d pos=%zu text=%s\n", cmd.tag, caret,
           EscapeForLog(value).c_str());
    printf("rn-impeller: selection tag=%d anchor=%zu caret=%zu command=1\n",
           cmd.tag, anchor, caret);
    fflush(stdout);
    // ENG-24: JS replaced the text (a composer cleared after send): report
    // the new size so the field can shrink back.
    if (textChanged) emitContentSizeIfChanged(cmd.tag);
    // A command does NOT fire onChange (JS already holds the text it set),
    // but the selection change is reported, as on iOS.
    auto te = std::dynamic_pointer_cast<const react::TextInputEventEmitter>(
        sceneGraph_->eventEmitterFor(tag));
    if (te) {
      react::TextInputEventEmitter::Metrics m{};
      m.text = value;
      m.eventCount = ++tiEventCount_;
      const int lo = (int)Utf8OffsetToUtf16Units(value, std::min(anchor, caret));
      const int hi = (int)Utf8OffsetToUtf16Units(value, std::max(anchor, caret));
      m.selectionRange.location = lo;
      m.selectionRange.length = hi - lo;
      runtimeScheduler_->scheduleWork(
          [te, m](facebook::jsi::Runtime&) { te->onSelectionChange(m); });
    }
    return;
  }
}

// item 11. Focus traversal helpers.
void FabricHost::emitTextInputFocusEvent(int tag, bool focus) {
  auto te = std::dynamic_pointer_cast<const react::TextInputEventEmitter>(
      sceneGraph_->eventEmitterFor(tag));
  if (!te) return;
  react::TextInputEventEmitter::Metrics m{};
  m.text = sceneGraph_->textInputValueFor(tag);
  m.eventCount = ++tiEventCount_;
  runtimeScheduler_->scheduleWork([te, m, focus](facebook::jsi::Runtime&) {
    if (focus) {
      te->onFocus(m);
    } else {
      te->onBlur(m);
    }
  });
}

// A plain View has no onFocus/onBlur method on its C++ emitter; dispatch the
// generic event, which normalizes to topFocus/topBlur (both registered in
// BaseViewConfig.ios.js's bubblingEventTypes).
void FabricHost::emitViewFocusEvent(int tag, bool focus) {
  auto emitter = sceneGraph_->eventEmitterFor(tag);
  if (!emitter) return;
  const int t = (int)tag;
  runtimeScheduler_->scheduleWork([emitter, focus, t](facebook::jsi::Runtime&) {
    emitter->dispatchEvent(
        focus ? "focus" : "blur", [t](facebook::jsi::Runtime& runtime) {
          auto payload = facebook::jsi::Object(runtime);
          payload.setProperty(runtime, "target", t);
          return facebook::jsi::Value(std::move(payload));
        });
  });
}

void FabricHost::blurFocusedView() {
  if (!sceneGraph_) return;
  const react::Tag v = sceneGraph_->focusedView();
  if (v == 0) return;
  sceneGraph_->setFocusedView(0);
  if (runtimeScheduler_) emitViewFocusEvent(v, false);
}

int FabricHost::moveFocus(bool forward) {
  if (!sceneGraph_ || !runtimeScheduler_) return 0;
  const auto order = sceneGraph_->tabOrder();
  react::Tag from = sceneGraph_->focusedTextInput();
  if (from == 0) from = sceneGraph_->focusedView();
  if (order.empty()) return 0;
  // Next/previous in tree order, wrapping. With nothing focused (or focus on
  // something no longer in the order), Tab starts at the first element and
  // Shift+Tab at the last.
  int idx = -1;
  for (size_t i = 0; i < order.size(); ++i) {
    if (order[i] == from) {
      idx = (int)i;
      break;
    }
  }
  const int n = (int)order.size();
  int next;
  if (idx < 0) {
    next = forward ? 0 : n - 1;
  } else {
    next = forward ? (idx + 1) % n : (idx - 1 + n) % n;
  }
  const react::Tag to = order[(size_t)next];
  printf("rn-impeller: focus_move from=%d to=%d dir=%s\n", (int)from, (int)to,
         forward ? "next" : "prev");
  fflush(stdout);
  if (to == from) return (int)to;

  // Blur whatever had focus.
  if (react::Tag prevField = sceneGraph_->focusedTextInput()) {
    emitTextInputFocusEvent(prevField, false);
    sceneGraph_->clearTextInputFocus();
    dragTag_ = 0;
  }
  blurFocusedView();

  if (sceneGraph_->isTextInputTag(to)) {
    // Tabbing into a field selects all of its text (macOS and Windows).
    sceneGraph_->setTextInputFocus(to);
    emitTextInputFocusEvent(to, true);
    const std::string value = sceneGraph_->textInputValueFor(to);
    if (!value.empty()) {
      sceneGraph_->setTextInputSelection(to, value, 0, value.size());
    }
    // Report what the scene graph ACTUALLY holds, not what was intended, so
    // the stdout line and onSelectionChange can never claim a selection the
    // editor does not have.
    const size_t selA = sceneGraph_->textInputSelectionAnchorFor(to);
    const size_t selC = sceneGraph_->textInputCaretFor(to);
    printf("rn-impeller: selection tag=%d anchor=%zu caret=%zu tab=1\n",
           (int)to, selA, selC);
    fflush(stdout);
    auto te = std::dynamic_pointer_cast<const react::TextInputEventEmitter>(
        sceneGraph_->eventEmitterFor(to));
    if (te) {
      react::TextInputEventEmitter::Metrics m{};
      m.text = value;
      m.eventCount = ++tiEventCount_;
      const int lo = (int)Utf8OffsetToUtf16Units(value, std::min(selA, selC));
      const int hi = (int)Utf8OffsetToUtf16Units(value, std::max(selA, selC));
      m.selectionRange.location = lo;
      m.selectionRange.length = hi - lo;
      runtimeScheduler_->scheduleWork(
          [te, m](facebook::jsi::Runtime&) { te->onSelectionChange(m); });
    }
  } else {
    sceneGraph_->setFocusedView(to);
    emitViewFocusEvent(to, true);
  }
  return (int)to;
}

}  // namespace rni
