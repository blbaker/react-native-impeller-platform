// rni-webhelper views: one WebKitWebView per engine web view, signals mapped
// to react-native-webview's event set.
//
//   load-changed STARTED   -> loadStart + navState(loading)
//   load-failed            -> error (then loadEnd from FINISHED)
//   load-changed FINISHED  -> load (unless it failed) + loadEnd + navState
//   notify::title / ::uri  -> navState   (canGoBack/canGoForward ride along)
//   create (window.open, target=_blank) -> loads in the SAME view
//   permission-request     -> media key system ALLOWED (EME is denied by
//                             default: measured in the 10-01 probe), all else denied
#include <cstdio>
#include <string>

#include "helper.h"

namespace rniweb {
namespace {

std::string NavJson(View* v, bool loading) {
  const char* uri = webkit_web_view_get_uri(v->web);
  const char* title = webkit_web_view_get_title(v->web);
  std::string j = "{\"url\":" + JsonEscape(uri ? uri : "") +
                  ",\"title\":" + JsonEscape(title ? title : "") +
                  ",\"loading\":" + (loading ? "true" : "false") +
                  ",\"canGoBack\":" + (webkit_web_view_can_go_back(v->web) ? "true" : "false") +
                  ",\"canGoForward\":" +
                  (webkit_web_view_can_go_forward(v->web) ? "true" : "false") + "}";
  return j;
}

void OnLoadChanged(WebKitWebView*, WebKitLoadEvent ev, gpointer data) {
  auto* v = static_cast<View*>(data);
  if (ev == WEBKIT_LOAD_STARTED) {
    v->failed = false;
    SendEvent(v->id, "loadStart", NavJson(v, true));
    SendEvent(v->id, "navState", NavJson(v, true));
  } else if (ev == WEBKIT_LOAD_FINISHED) {
    if (!v->failed) SendEvent(v->id, "load", NavJson(v, false));
    SendEvent(v->id, "loadEnd", NavJson(v, false));
    SendEvent(v->id, "navState", NavJson(v, false));
  }
}

gboolean OnLoadFailed(WebKitWebView*, WebKitLoadEvent, gchar* uri, GError* err, gpointer data) {
  auto* v = static_cast<View*>(data);
  v->failed = true;  // no onLoad for this navigation either way
  // A cancelled load (stopLoading, or a new navigation replacing a pending
  // one) is not an error: react-native-webview drops NSURLErrorCancelled the
  // same way. onLoadEnd still follows from FINISHED.
  if (g_error_matches(err, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED)) return FALSE;
  std::string j = NavJson(v, false);
  j.pop_back();
  j += ",\"failingUrl\":" + JsonEscape(uri ? uri : "") + ",\"code\":" + std::to_string(err->code) +
       ",\"domain\":" + JsonEscape(g_quark_to_string(err->domain)) +
       ",\"description\":" + JsonEscape(err->message) + "}";
  // RNW reports the URL that FAILED as nativeEvent.url (Android onReceivedError).
  const size_t u = j.find("\"url\":");
  const size_t e = j.find(",\"title\":");
  if (u != std::string::npos && e != std::string::npos)
    j.replace(u, e - u, "\"url\":" + JsonEscape(uri ? uri : ""));
  SendEvent(v->id, "error", j);
  // Handled: no WebKit error page. Its load would fire a second STARTED /
  // FINISHED pair and an onLoad for the failed URL, which react-native-webview
  // never does (the app renders its own error UI). FINISHED -> onLoadEnd follows.
  return TRUE;
}

void OnNotify(GObject*, GParamSpec*, gpointer data) {
  auto* v = static_cast<View*>(data);
  SendEvent(v->id, "navState", NavJson(v, webkit_web_view_is_loading(v->web)));
}

WebKitWebView* OnCreate(WebKitWebView*, WebKitNavigationAction* action, gpointer data) {
  auto* v = static_cast<View*>(data);
  WebKitURIRequest* req = webkit_navigation_action_get_request(action);
  const char* uri = req ? webkit_uri_request_get_uri(req) : nullptr;
  if (uri && *uri) webkit_web_view_load_uri(v->web, uri);
  return nullptr;  // no second view: window.open opens in this one
}

gboolean OnPermission(WebKitWebView*, WebKitPermissionRequest* req, gpointer) {
  if (WEBKIT_IS_MEDIA_KEY_SYSTEM_PERMISSION_REQUEST(req)) webkit_permission_request_allow(req);
  else webkit_permission_request_deny(req);
  return TRUE;
}

void OnBufferRendered(WPEView*, WPEBuffer* buffer, gpointer data) {
  OnBuffer(static_cast<View*>(data), buffer);
}

}  // namespace

View* CreateView(uint32_t id, int w, int h, double scale, const std::string& ua) {
  auto* v = new View();
  v->id = id;
  v->scale = scale > 0 ? scale : 1;
  WebKitSettings* s = webkit_settings_new();
  webkit_settings_set_enable_encrypted_media(s, TRUE);
  webkit_settings_set_enable_mediasource(s, TRUE);
  webkit_settings_set_media_playback_requires_user_gesture(s, FALSE);  // autoplay with audio
  webkit_settings_set_javascript_can_open_windows_automatically(s, TRUE);
  webkit_settings_set_enable_write_console_messages_to_stdout(s, TRUE);
  if (!ua.empty()) webkit_settings_set_user_agent(s, ua.c_str());
  v->ucm = webkit_user_content_manager_new();
  v->web = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", H().display,
                                        "network-session", H().session, "settings", s,
                                        "user-content-manager", v->ucm, nullptr));
  g_object_unref(s);
  g_signal_connect(v->web, "load-changed", G_CALLBACK(OnLoadChanged), v);
  g_signal_connect(v->web, "load-failed", G_CALLBACK(OnLoadFailed), v);
  g_signal_connect(v->web, "notify::title", G_CALLBACK(OnNotify), v);
  g_signal_connect(v->web, "notify::uri", G_CALLBACK(OnNotify), v);
  g_signal_connect(v->web, "create", G_CALLBACK(OnCreate), v);
  g_signal_connect(v->web, "permission-request", G_CALLBACK(OnPermission), v);
  InstallInputMethod(v);
  v->wpe = webkit_web_view_get_wpe_view(v->web);
  WPEToplevel* top = wpe_view_get_toplevel(v->wpe);
  if (v->scale != 1) wpe_toplevel_scale_changed(top, v->scale);
  wpe_toplevel_resize(top, w > 0 ? w : 1, h > 0 ? h : 1);
  g_signal_connect(v->wpe, "buffer-rendered", G_CALLBACK(OnBufferRendered), v);
  printf("rni-webhelper: view %u created %dx%d scale=%.2f\n", id, w, h, v->scale);
  static bool modelLogged = false;  // main.cpp sets it before the first context exists
  if (!modelLogged) {
    modelLogged = true;
    const WebKitCacheModel m = webkit_web_context_get_cache_model(webkit_web_view_get_context(v->web));
    printf("rni-webhelper: cache_model=%s\n", m == WEBKIT_CACHE_MODEL_DOCUMENT_BROWSER ? "document_browser"
                                              : m == WEBKIT_CACHE_MODEL_DOCUMENT_VIEWER ? "document_viewer"
                                                                                        : "web_browser");
  }
  return v;
}

// Releases what the view holds. It does NOT free `v`: H().views owns it (a
// unique_ptr), and the caller's erase deletes it. Deleting it here too was a
// double free that aborted the helper on every view destroy (glibc "double
// free or corruption (!prev)"), taking every other view down with it.
void DestroyView(View* v) {
  ReleaseInputMethod(v);
  g_signal_handlers_disconnect_by_data(v->web, v);
  g_signal_handlers_disconnect_by_data(v->wpe, v);
  webkit_web_view_try_close(v->web);
  g_object_unref(v->web);
  g_object_unref(v->ucm);
  v->web = nullptr;
  v->wpe = nullptr;
  v->ucm = nullptr;
  FreeFrames(&v->frames);
  printf("rni-webhelper: view %u destroyed frames=%llu dropped=%llu\n", v->id,
         (unsigned long long)v->frames.seq, (unsigned long long)v->frames.dropped);
}

void LoadUrl(View* v, const std::string& url, const std::string& headers) {
  WebKitURIRequest* req = webkit_uri_request_new(url.c_str());
  // react-native-webview semantics: source.headers ride on the TOP-LEVEL
  // request only.
  SoupMessageHeaders* hs = webkit_uri_request_get_http_headers(req);
  int n = 0;
  for (auto& [k, val] : rni::webproto::SplitHeaders(headers)) {
    if (hs) soup_message_headers_replace(hs, k.c_str(), val.c_str());
    ++n;
  }
  printf("rni-webhelper: view %u load %s headers=%d\n", v->id, url.c_str(), n);
  webkit_web_view_load_request(v->web, req);
  g_object_unref(req);
}

void SetUserScripts(View* v) {
  webkit_user_content_manager_remove_all_scripts(v->ucm);
  auto add = [&](const std::string& js, WebKitUserScriptInjectionTime when) {
    if (js.empty()) return;
    WebKitUserScript* s = webkit_user_script_new(js.c_str(), WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
                                                 when, nullptr, nullptr);
    webkit_user_content_manager_add_script(v->ucm, s);
    webkit_user_script_unref(s);
  };
  add(v->scriptStart, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START);
  add(v->scriptEnd, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END);
}

}  // namespace rniweb
