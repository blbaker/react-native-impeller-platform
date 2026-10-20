// iOS host: see RNITextInputView.h. Built with -fobjc-arc.
#import "ios/RNITextInputView.h"

#include <react/renderer/components/iostextinput/primitives.h>

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <string>

#include "fabric/FabricHost.h"

static_assert(__has_feature(objc_arc), "RNITextInputView.mm must be built with -fobjc-arc");

using rni::FabricHost;
namespace react = facebook::react;

// ---------------------------------------------------------------------------
@interface RNITextPosition : UITextPosition
@property(nonatomic, readonly) NSUInteger index;
+ (instancetype)at:(NSUInteger)index;
@end

@implementation RNITextPosition
+ (instancetype)at:(NSUInteger)index {
  RNITextPosition* p = [self new];
  p->_index = index;
  return p;
}
@end

@interface RNITextRange : UITextRange
@property(nonatomic, readonly) NSRange range;
+ (instancetype)with:(NSRange)range;
@end

@implementation RNITextRange
+ (instancetype)with:(NSRange)range {
  RNITextRange* r = [self new];
  r->_range = range;
  return r;
}
- (UITextPosition*)start {
  return [RNITextPosition at:_range.location];
}
- (UITextPosition*)end {
  return [RNITextPosition at:NSMaxRange(_range)];
}
- (BOOL)isEmpty {
  return _range.length == 0;
}
@end

static NSUInteger Idx(UITextPosition* p) {
  return [p isKindOfClass:RNITextPosition.class] ? ((RNITextPosition*)p).index : 0;
}

static NSRange Rng(UITextRange* r) {
  return [r isKindOfClass:RNITextRange.class] ? ((RNITextRange*)r).range : NSMakeRange(0, 0);
}

static NSString* NS(const std::string& s) {
  return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding]
             ?: @"";
}

static std::string Std(NSString* s) {
  const char* c = s.UTF8String;
  return c ? std::string(c) : std::string();
}

static void Log(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static void Log(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  std::vfprintf(stdout, fmt, ap);
  va_end(ap);
  std::fflush(stdout);
}

// ---------------------------------------------------------------------------
@implementation RNITextInputView {
  NSMutableString* _text;
  NSRange _sel;
  NSRange _marked;  // location NSNotFound: nothing marked
  int _tag;
  UITextInputStringTokenizer* _tokenizer;
}

@synthesize inputDelegate = _inputDelegate;
@synthesize markedTextStyle = _markedTextStyle;
// UITextInputTraits (optional protocol properties), set from the field's props.
@synthesize autocapitalizationType = _autocapitalizationType;
@synthesize autocorrectionType = _autocorrectionType;
@synthesize spellCheckingType = _spellCheckingType;
@synthesize keyboardType = _keyboardType;
@synthesize keyboardAppearance = _keyboardAppearance;
@synthesize returnKeyType = _returnKeyType;
@synthesize enablesReturnKeyAutomatically = _enablesReturnKeyAutomatically;
@synthesize secureTextEntry = _secureTextEntry;

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _text = [NSMutableString new];
    _sel = NSMakeRange(0, 0);
    _marked = NSMakeRange(NSNotFound, 0);
    _tokenizer = [[UITextInputStringTokenizer alloc] initWithTextInput:self];
    self.userInteractionEnabled = NO;  // never the target of a touch
    self.hidden = YES;                 // draws nothing; the engine paints the field
  }
  return self;
}

- (BOOL)canBecomeFirstResponder {
  return YES;
}

- (BOOL)becomeFirstResponder {
  const BOOL ok = [super becomeFirstResponder];
  Log("rni-ios: keyboard first_responder=%d\n", ok);
  return ok;
}

- (BOOL)resignFirstResponder {
  _marked = NSMakeRange(NSNotFound, 0);
  const BOOL ok = [super resignFirstResponder];
  Log("rni-ios: keyboard resigned=%d\n", ok);
  return ok;
}

// --- engine <-> copy --------------------------------------------------------

- (NSRange)clamp:(NSRange)r {
  const NSUInteger n = _text.length;
  const NSUInteger loc = std::min<NSUInteger>(r.location, n);
  return NSMakeRange(loc, std::min<NSUInteger>(r.length, n - loc));
}

- (void)applyTraits:(const rni::TextInputKeyboardTraits&)t {
  switch ((react::AutocapitalizationType)t.autoCapitalize) {
    case react::AutocapitalizationType::None:
      self.autocapitalizationType = UITextAutocapitalizationTypeNone;
      break;
    case react::AutocapitalizationType::Words:
      self.autocapitalizationType = UITextAutocapitalizationTypeWords;
      break;
    case react::AutocapitalizationType::Characters:
      self.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
      break;
    default:
      self.autocapitalizationType = UITextAutocapitalizationTypeSentences;
  }
  self.autocorrectionType = t.autoCorrect < 0    ? UITextAutocorrectionTypeDefault
                            : t.autoCorrect == 1 ? UITextAutocorrectionTypeYes
                                                 : UITextAutocorrectionTypeNo;
  self.spellCheckingType = t.spellCheck < 0    ? UITextSpellCheckingTypeDefault
                           : t.spellCheck == 1 ? UITextSpellCheckingTypeYes
                                               : UITextSpellCheckingTypeNo;
  // As RN's own iOS TextInput maps them (RCTTextInputUtils).
  switch ((react::KeyboardType)t.keyboardType) {
    case react::KeyboardType::EmailAddress: self.keyboardType = UIKeyboardTypeEmailAddress; break;
    case react::KeyboardType::Numeric: self.keyboardType = UIKeyboardTypeDecimalPad; break;
    case react::KeyboardType::PhonePad: self.keyboardType = UIKeyboardTypePhonePad; break;
    case react::KeyboardType::NumberPad: self.keyboardType = UIKeyboardTypeNumberPad; break;
    case react::KeyboardType::DecimalPad: self.keyboardType = UIKeyboardTypeDecimalPad; break;
    case react::KeyboardType::ASCIICapable: self.keyboardType = UIKeyboardTypeASCIICapable; break;
    case react::KeyboardType::NumbersAndPunctuation:
      self.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
      break;
    case react::KeyboardType::URL: self.keyboardType = UIKeyboardTypeURL; break;
    case react::KeyboardType::NamePhonePad: self.keyboardType = UIKeyboardTypeNamePhonePad; break;
    case react::KeyboardType::Twitter: self.keyboardType = UIKeyboardTypeTwitter; break;
    case react::KeyboardType::WebSearch: self.keyboardType = UIKeyboardTypeWebSearch; break;
    case react::KeyboardType::ASCIICapableNumberPad:
      self.keyboardType = UIKeyboardTypeASCIICapableNumberPad;
      break;
    default: self.keyboardType = UIKeyboardTypeDefault;
  }
  switch ((react::ReturnKeyType)t.returnKeyType) {
    case react::ReturnKeyType::Done: self.returnKeyType = UIReturnKeyDone; break;
    case react::ReturnKeyType::Go: self.returnKeyType = UIReturnKeyGo; break;
    case react::ReturnKeyType::Next: self.returnKeyType = UIReturnKeyNext; break;
    case react::ReturnKeyType::Search: self.returnKeyType = UIReturnKeySearch; break;
    case react::ReturnKeyType::Send: self.returnKeyType = UIReturnKeySend; break;
    case react::ReturnKeyType::EmergencyCall: self.returnKeyType = UIReturnKeyEmergencyCall; break;
    case react::ReturnKeyType::Google: self.returnKeyType = UIReturnKeyGoogle; break;
    case react::ReturnKeyType::Join: self.returnKeyType = UIReturnKeyJoin; break;
    case react::ReturnKeyType::Route: self.returnKeyType = UIReturnKeyRoute; break;
    case react::ReturnKeyType::Yahoo: self.returnKeyType = UIReturnKeyYahoo; break;
    case react::ReturnKeyType::Continue: self.returnKeyType = UIReturnKeyContinue; break;
    default: self.returnKeyType = UIReturnKeyDefault;
  }
  switch ((react::KeyboardAppearance)t.keyboardAppearance) {
    case react::KeyboardAppearance::Light: self.keyboardAppearance = UIKeyboardAppearanceLight; break;
    case react::KeyboardAppearance::Dark: self.keyboardAppearance = UIKeyboardAppearanceDark; break;
    default: self.keyboardAppearance = UIKeyboardAppearanceDefault;
  }
  self.enablesReturnKeyAutomatically = t.enablesReturnKeyAutomatically;
  self.secureTextEntry = t.secure;
  Log("rni-ios: keyboard traits autocap=%d autocorrect=%d spellcheck=%d type=%d return=%d "
      "secure=%d\n",
      (int)self.autocapitalizationType, (int)self.autocorrectionType, (int)self.spellCheckingType,
      (int)self.keyboardType, (int)self.returnKeyType, (int)self.secureTextEntry);
}

- (void)copyState:(const FabricHost::TextInputState&)st {
  _tag = st.tag;
  _text = [NS(st.value) mutableCopy];
  _sel = [self clamp:NSMakeRange(st.selStart, st.selEnd - std::min(st.selStart, st.selEnd))];
}

- (void)loadFromEngine {
  FabricHost::TextInputState st;
  if (!_fabric || !_fabric->textInputState(&st)) return;
  rni::TextInputKeyboardTraits traits;
  if (_fabric->textInputKeyboardTraits(&traits)) [self applyTraits:traits];
  _marked = NSMakeRange(NSNotFound, 0);
  [self copyState:st];
}

- (void)syncFromEngine {
  if (!_fabric || !self.isFirstResponder) return;
  FabricHost::TextInputState st;
  if (!_fabric->textInputState(&st)) return;
  if (st.tag != _tag) {  // focus moved to another field: new text, new traits
    [_inputDelegate textWillChange:self];
    [self loadFromEngine];
    [_inputDelegate textDidChange:self];
    [self reloadInputViews];
    Log("rni-ios: text refocus tag=%d len=%lu\n", _tag, (unsigned long)_text.length);
    return;
  }
  if (_marked.location != NSNotFound) return;  // never fight a composition
  NSString* value = NS(st.value);
  const NSRange sel = NSMakeRange(st.selStart, st.selEnd - std::min(st.selStart, st.selEnd));
  const BOOL textChanged = ![value isEqualToString:_text];
  if (!textChanged && NSEqualRanges(sel, _sel)) return;
  if (textChanged) [_inputDelegate textWillChange:self];
  [_inputDelegate selectionWillChange:self];
  [self copyState:st];
  [_inputDelegate selectionDidChange:self];
  if (textChanged) [_inputDelegate textDidChange:self];
  Log("rni-ios: text from_engine len=%lu sel=%lu,%lu\n", (unsigned long)_text.length,
      (unsigned long)_sel.location, (unsigned long)_sel.length);
}

// The one edit path: the copy first, then the engine (which fires onChange).
- (void)replace:(NSRange)r with:(NSString*)s selection:(NSRange)sel {
  r = [self clamp:r];
  [_text replaceCharactersInRange:r withString:s];
  _sel = [self clamp:sel];
  if (_fabric) {
    _fabric->replaceTextInputRange(r.location, NSMaxRange(r), Std(s), _sel.location,
                                   NSMaxRange(_sel));
  }
}

// --- UIKeyInput -------------------------------------------------------------

- (BOOL)hasText {
  return _text.length > 0;
}

- (void)insertText:(NSString*)text {
  if (!_fabric) return;
  if ([text isEqualToString:@"\n"] && _marked.location == NSNotFound) {
    // Return: the engine decides submit vs newline (submitBehavior), as on desktop.
    const int tag = _fabric->dispatchKey(FabricHost::KeyAction::Submit, 0);
    FabricHost::TextInputState st;
    if (_fabric->textInputState(&st)) [self copyState:st];
    Log("rni-ios: text return tag=%d\n", tag);
    return;
  }
  const NSRange r = _marked.location != NSNotFound ? _marked : _sel;
  [self replace:r with:text selection:NSMakeRange(r.location + text.length, 0)];
  _marked = NSMakeRange(NSNotFound, 0);
  Log("rni-ios: text insert len=%lu at=%lu\n", (unsigned long)text.length,
      (unsigned long)r.location);
}

- (void)deleteBackward {
  if (!_fabric) return;
  NSRange r = _sel;
  if (r.length == 0) {
    if (r.location == 0) return;
    r = [_text rangeOfComposedCharacterSequenceAtIndex:r.location - 1];
  }
  [self replace:r with:@"" selection:NSMakeRange(r.location, 0)];
  if (_marked.location != NSNotFound && NSIntersectionRange(r, _marked).length > 0) {
    _marked = NSMakeRange(NSNotFound, 0);
  }
  Log("rni-ios: text delete len=%lu at=%lu\n", (unsigned long)r.length, (unsigned long)r.location);
}

// --- UITextInput: text and selection -----------------------------------------

- (NSString*)textInRange:(UITextRange*)range {
  return [_text substringWithRange:[self clamp:Rng(range)]];
}

- (void)replaceRange:(UITextRange*)range withText:(NSString*)text {
  const NSRange r = [self clamp:Rng(range)];
  [self replace:r with:text selection:NSMakeRange(r.location + text.length, 0)];
  if (_marked.location != NSNotFound && NSIntersectionRange(r, _marked).length > 0) {
    _marked = NSMakeRange(NSNotFound, 0);
  }
  Log("rni-ios: text replace range=%lu,%lu len=%lu\n", (unsigned long)r.location,
      (unsigned long)r.length, (unsigned long)text.length);
}

- (UITextRange*)selectedTextRange {
  return [RNITextRange with:_sel];
}

- (void)setSelectedTextRange:(UITextRange*)range {
  _sel = [self clamp:Rng(range)];
  if (_fabric) {
    _fabric->replaceTextInputRange(_sel.location, _sel.location, std::string(), _sel.location,
                                   NSMaxRange(_sel));
  }
}

- (UITextRange*)markedTextRange {
  return _marked.location == NSNotFound ? nil : [RNITextRange with:_marked];
}

- (void)setMarkedText:(NSString*)markedText selectedRange:(NSRange)selectedRange {
  NSString* t = markedText ?: @"";
  const NSRange r = _marked.location != NSNotFound ? _marked : _sel;
  const NSUInteger selLoc = std::min<NSUInteger>(selectedRange.location, t.length);
  const NSUInteger selLen = std::min<NSUInteger>(selectedRange.length, t.length - selLoc);
  [self replace:r with:t selection:NSMakeRange(r.location + selLoc, selLen)];
  _marked = t.length ? NSMakeRange(r.location, t.length) : NSMakeRange(NSNotFound, 0);
  Log("rni-ios: text marked len=%lu at=%lu\n", (unsigned long)t.length, (unsigned long)r.location);
}

- (void)unmarkText {
  if (_marked.location == NSNotFound) return;
  Log("rni-ios: text unmark len=%lu\n", (unsigned long)_marked.length);
  _marked = NSMakeRange(NSNotFound, 0);
}

// --- UITextInput: positions --------------------------------------------------

- (UITextPosition*)beginningOfDocument {
  return [RNITextPosition at:0];
}

- (UITextPosition*)endOfDocument {
  return [RNITextPosition at:_text.length];
}

- (UITextRange*)textRangeFromPosition:(UITextPosition*)from toPosition:(UITextPosition*)to {
  const NSUInteger a = Idx(from), b = Idx(to);
  return [RNITextRange with:NSMakeRange(std::min(a, b), a > b ? a - b : b - a)];
}

- (UITextPosition*)positionFromPosition:(UITextPosition*)position offset:(NSInteger)offset {
  const NSInteger i = (NSInteger)Idx(position) + offset;
  return (i < 0 || i > (NSInteger)_text.length) ? nil : [RNITextPosition at:(NSUInteger)i];
}

- (UITextPosition*)positionFromPosition:(UITextPosition*)position
                            inDirection:(UITextLayoutDirection)direction
                                 offset:(NSInteger)offset {
  const BOOL back =
      direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp;
  return [self positionFromPosition:position offset:back ? -offset : offset];
}

- (NSComparisonResult)comparePosition:(UITextPosition*)position toPosition:(UITextPosition*)other {
  const NSUInteger a = Idx(position), b = Idx(other);
  return a < b ? NSOrderedAscending : a > b ? NSOrderedDescending : NSOrderedSame;
}

- (NSInteger)offsetFromPosition:(UITextPosition*)from toPosition:(UITextPosition*)to {
  return (NSInteger)Idx(to) - (NSInteger)Idx(from);
}

- (id<UITextInputTokenizer>)tokenizer {
  return _tokenizer;
}

- (UITextPosition*)positionWithinRange:(UITextRange*)range
                   farthestInDirection:(UITextLayoutDirection)direction {
  const BOOL back =
      direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp;
  return back ? range.start : range.end;
}

- (UITextRange*)characterRangeByExtendingPosition:(UITextPosition*)position
                                      inDirection:(UITextLayoutDirection)direction {
  const NSUInteger i = std::min<NSUInteger>(Idx(position), _text.length);
  const BOOL back =
      direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp;
  return [RNITextRange with:back ? NSMakeRange(0, i) : NSMakeRange(i, _text.length - i)];
}

- (NSWritingDirection)baseWritingDirectionForPosition:(UITextPosition*)position
                                          inDirection:(UITextStorageDirection)direction {
  return NSWritingDirectionLeftToRight;
}

- (void)setBaseWritingDirection:(NSWritingDirection)writingDirection
                       forRange:(UITextRange*)range {
}

// --- UITextInput: geometry (this view sits at the engine view's origin, so
// the engine's layout points are this view's coordinates) ---------------------

- (CGRect)caretRectForPosition:(UITextPosition*)position {
  float x = 0, y = 0, w = 0, h = 0;
  if (!_fabric || !_fabric->textInputCaretRect(Idx(position), &x, &y, &w, &h)) return CGRectZero;
  return CGRectMake(x, y, w, h);
}

- (CGRect)firstRectForRange:(UITextRange*)range {
  const CGRect a = [self caretRectForPosition:range.start];
  const CGRect b = [self caretRectForPosition:range.end];
  return CGRectMake(a.origin.x, a.origin.y, std::max<CGFloat>(1, b.origin.x - a.origin.x),
                    a.size.height);
}

- (NSArray<UITextSelectionRect*>*)selectionRectsForRange:(UITextRange*)range {
  return @[];
}

- (UITextPosition*)closestPositionToPoint:(CGPoint)point {
  return [RNITextPosition at:_text.length];
}

- (UITextPosition*)closestPositionToPoint:(CGPoint)point withinRange:(UITextRange*)range {
  return range.end;
}

- (UITextRange*)characterRangeAtPoint:(CGPoint)point {
  return [RNITextRange with:NSMakeRange(_text.length, 0)];
}

@end
