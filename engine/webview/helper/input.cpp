// rni-webhelper input: protocol input messages -> real WPEEvents through
// wpe_view_event, the path a WPE platform's own seat uses.
//
// Mouse model (decided by the engine's router, engine/webview/WebViewInput.cpp):
//   hover / right / middle buttons -> WPE pointer events (source MOUSE)
//   left-button press, drag, release -> ONE touch sequence (source TOUCHSCREEN).
// WebKit's WPE view runs its gesture controller on touches the page did not
// consume (WPEWebViewPlatform.cpp handleGesture): a tap becomes a click, a drag
// becomes a scroll, and a page with touch handlers (carousels, maps) gets the
// raw touches. That is the touchscreen behaviour the device has, on a mouse.
#include <algorithm>
#include <cstdio>

#include "helper.h"

namespace rniweb {
namespace wp = rni::webproto;
namespace {

guint32 Now() { return (guint32)(g_get_monotonic_time() / 1000); }

WPEModifiers Mods(uint32_t m) {
  unsigned r = 0;
  if (m & wp::kShift) r |= WPE_MODIFIER_KEYBOARD_SHIFT;
  if (m & wp::kCtrl) r |= WPE_MODIFIER_KEYBOARD_CONTROL;
  if (m & wp::kAlt) r |= WPE_MODIFIER_KEYBOARD_ALT;
  if (m & wp::kMeta) r |= WPE_MODIFIER_KEYBOARD_META;
  if (m & wp::kCaps) r |= WPE_MODIFIER_KEYBOARD_CAPS_LOCK;
  if (m & wp::kButton1) r |= WPE_MODIFIER_POINTER_BUTTON1;
  return (WPEModifiers)r;
}

void Post(View* v, WPEEvent* e, const char* what) {
  if (!e) {  // WPE returns NULL for an invalid combination (e.g. UP with a press count)
    fprintf(stderr, "rni-webhelper: WPE rejected %s event\n", what);
    return;
  }
  wpe_view_event(v->wpe, e);
  wpe_event_unref(e);
}

// App-drawn keyboard (the board image has no OS input method). Each view gets
// its own WebKitInputMethodContext. WebKit's InputMethodFilter calls
// notify_focus_in / notify_focus_out when an editable gains or loses input
// focus while the view is focused, with input-purpose already set. Moving focus
// straight from one editable to another can change only input-purpose, so that
// notify is a report too. kText is emitted as the context's "committed" signal,
// the signal a real IME commit uses: WebKit inserts the text (beforeinput/input
// fire) with no keysym mapping. Key events are not filtered (no filter_key_event
// vfunc), so the physical keyboard path below is unchanged.
struct RniImContext {
  WebKitInputMethodContext parent;
  View* view;  // null once the view is being destroyed
  bool focused;
  WebKitInputPurpose purpose;  // the last one reported
};
struct RniImContextClass {
  WebKitInputMethodContextClass parent;
};
G_DEFINE_TYPE(RniImContext, rni_im_context, WEBKIT_TYPE_INPUT_METHOD_CONTEXT)

RniImContext* Im(gpointer p) { return static_cast<RniImContext*>(p); }

const char* PurposeName(WebKitInputPurpose p) {
  switch (p) {
    case WEBKIT_INPUT_PURPOSE_DIGITS: return "digits";
    case WEBKIT_INPUT_PURPOSE_NUMBER: return "number";
    case WEBKIT_INPUT_PURPOSE_PHONE: return "phone";
    case WEBKIT_INPUT_PURPOSE_URL: return "url";
    case WEBKIT_INPUT_PURPOSE_EMAIL: return "email";
    case WEBKIT_INPUT_PURPOSE_PASSWORD: return "password";
    case WEBKIT_INPUT_PURPOSE_SEARCH: return "search";
    default: return "free-form";
  }
}

void ReportFocus(RniImContext* c, bool focused) {
  const WebKitInputPurpose p = webkit_input_method_context_get_input_purpose(&c->parent);
  if (!c->view || (focused == c->focused && (!focused || p == c->purpose))) return;
  c->focused = focused;
  c->purpose = p;
  const bool password = focused && p == WEBKIT_INPUT_PURPOSE_PASSWORD;
  SendEvent(c->view->id, "editableFocus",
            std::string("{\"focused\":") + (focused ? "true" : "false") +
                ",\"isPassword\":" + (password ? "true" : "false") +
                ",\"purpose\":" + (focused ? JsonEscape(PurposeName(p)) : "null") + "}");
}

void rni_im_context_init(RniImContext*) {}
void rni_im_context_class_init(RniImContextClass* klass) {
  klass->parent.notify_focus_in = [](WebKitInputMethodContext* c) { ReportFocus(Im(c), true); };
  klass->parent.notify_focus_out = [](WebKitInputMethodContext* c) { ReportFocus(Im(c), false); };
}

void OnPurpose(GObject* o, GParamSpec*, gpointer) {
  if (Im(o)->focused) ReportFocus(Im(o), true);
}

void CommitText(View* v, const std::string& text) {
  if (!Im(v->im)->focused)
    fprintf(stderr, "rni-webhelper: view %u text sent while no editable has input focus\n", v->id);
  g_signal_emit_by_name(v->im, "committed", text.c_str());
}

}  // namespace

void InstallInputMethod(View* v) {
  RniImContext* c = Im(g_object_new(rni_im_context_get_type(), nullptr));
  c->view = v;
  v->im = &c->parent;
  g_signal_connect(c, "notify::input-purpose", G_CALLBACK(OnPurpose), nullptr);
  webkit_web_view_set_input_method_context(v->web, v->im);  // the web view keeps its own ref
}

void ReleaseInputMethod(View* v) {
  Im(v->im)->view = nullptr;  // WebKit may still call notify_focus_out while the view closes
  g_object_unref(v->im);
  v->im = nullptr;
}

void HandleInput(View* v, const wp::Message& m) {
  const std::string& kind = m.s(0);
  if (m.type == wp::kText) {
    CommitText(v, m.s(0));
    return;
  }
  if (m.type == wp::kFocus) {
    if (m.s(0) == "1") wpe_view_focus_in(v->wpe);
    else wpe_view_focus_out(v->wpe);
    return;
  }
  if (m.type == wp::kPointer) {
    const guint button = (guint)m.i(1);
    const double x = m.d(2), y = m.d(3);
    const WPEModifiers mods = Mods((uint32_t)m.i(4));
    if (kind == "move" || kind == "enter" || kind == "leave") {
      const WPEEventType t = kind == "move"    ? WPE_EVENT_POINTER_MOVE
                             : kind == "enter" ? WPE_EVENT_POINTER_ENTER
                                               : WPE_EVENT_POINTER_LEAVE;
      Post(v, wpe_event_pointer_move_new(t, v->wpe, WPE_INPUT_SOURCE_MOUSE, Now(), mods, x, y, 0, 0),
           "pointer-move");
    } else if (kind == "down") {
      Post(v, wpe_event_pointer_button_new(WPE_EVENT_POINTER_DOWN, v->wpe, WPE_INPUT_SOURCE_MOUSE,
                                           Now(), mods, button, x, y, (guint)std::max(1LL, m.i(5))),
           "pointer-down");
    } else if (kind == "up") {
      Post(v, wpe_event_pointer_button_new(WPE_EVENT_POINTER_UP, v->wpe, WPE_INPUT_SOURCE_MOUSE,
                                           Now(), mods, button, x, y, 0),
           "pointer-up");
    }
    return;
  }
  if (m.type == wp::kTouch) {
    const double x = m.d(1), y = m.d(2);
    const WPEModifiers mods = Mods((uint32_t)m.i(3));
    WPEEventType t = WPE_EVENT_TOUCH_MOVE;
    if (kind == "down") t = WPE_EVENT_TOUCH_DOWN;
    else if (kind == "up") t = WPE_EVENT_TOUCH_UP;
    else if (kind == "cancel") t = WPE_EVENT_TOUCH_CANCEL;
    if (t == WPE_EVENT_TOUCH_DOWN) {
      v->touchDown = true;
      wpe_view_focus_in(v->wpe);
    } else if (!v->touchDown) {
      return;  // a move/up without a down would be a broken sequence
    }
    if (t == WPE_EVENT_TOUCH_UP || t == WPE_EVENT_TOUCH_CANCEL) v->touchDown = false;
    Post(v, wpe_event_touch_new(t, v->wpe, WPE_INPUT_SOURCE_TOUCHSCREEN, Now(), mods, 1, x, y),
         "touch");
    return;
  }
  if (m.type == wp::kScroll) {
    // Engine sends CSS px with the RN contentOffset sign (positive dy = scroll
    // DOWN the page). WPE scroll deltas are wheel-convention: positive = up.
    const double x = m.d(0), y = m.d(1), dx = m.d(2), dy = m.d(3);
    Post(v, wpe_event_scroll_new(v->wpe, WPE_INPUT_SOURCE_MOUSE, Now(), Mods((uint32_t)m.i(4)),
                                 -dx, -dy, TRUE, FALSE, x, y),
         "scroll");
    return;
  }
  if (m.type == wp::kKey) {
    const WPEEventType t = kind == "up" ? WPE_EVENT_KEYBOARD_KEY_UP : WPE_EVENT_KEYBOARD_KEY_DOWN;
    Post(v, wpe_event_keyboard_new(t, v->wpe, WPE_INPUT_SOURCE_KEYBOARD, Now(),
                                   Mods((uint32_t)m.i(3)), (guint)m.i(2), (guint)m.i(1)),
         "key");
  }
}

}  // namespace rniweb
