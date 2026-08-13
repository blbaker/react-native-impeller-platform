#include "modules/PlatformModules.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#ifdef _WIN32
// ShellExecuteW + the CP_UTF8 conversion for openURL below. WIN32_LEAN_AND_MEAN
// and NOMINMAX are set project-wide in engine/CMakeLists.txt (defining them
// again here is a C4005 redefinition warning); NOMINMAX in particular stops
// <windows.h> defining min/max as function-like macros, which turns any
// std::min( call in a TU into `C2589: '(' illegal token`.
#include <windows.h>
#include <shellapi.h>
#include <climits>  // INT_PTR comparison bound
#else
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace rni {

namespace {

// Resolve a JS value to a settled Promise. Everything this module does is
// synchronous, so there is nothing to await — but the codegen'd spec types
// these methods as promises and RN's Linking.js `await`s them. Returning a
// bare value would work by accident today (await on a non-thenable) and break
// the moment anything inspects the return type.
jsi::Value resolvedPromise(jsi::Runtime& rt, jsi::Value value) {
  auto promise = rt.global().getPropertyAsObject(rt, "Promise");
  auto resolve = promise.getPropertyAsFunction(rt, "resolve");
  return resolve.callWithThis(rt, promise, std::move(value));
}

bool isAsciiAlpha(char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

}  // namespace

// ---------------------------------------------------------------------------
// ⛔ THE ALLOWLIST IS A SECURITY BOUNDARY ON A PLATFORM THIS FILE CANNOT YET
// BUILD FOR, WHICH IS WHY IT LIVES HERE AND NOT BEHIND AN #ifdef.
//
// POSIX `execlp("xdg-open", url)` passes the URL as argv[1] with no shell, so
// the worst case is xdg-open declining it. The natural Windows translation,
// ShellExecuteW(nullptr, L"open", s, ...), resolves `s` THE WAY THE SHELL
// WOULD: handed cmd.exe, a .bat, a UNC path or a file:// URL, it launches it.
// Translating one-for-one ships the hole, and a Windows-only guard would be
// unverifiable until someone has a Windows build — precisely when it gets the
// least scrutiny.
//
// So the predicate is common, and the Linux CI that runs every day exercises
// the code protecting the OS that is not built yet.
//
// The rule is an ALLOWLIST, not a denylist: scheme must be one we name, and
// the rest of the string must contain no character a shell or ShellExecute
// would treat structurally. A denylist of "bad schemes" fails open on the next
// scheme somebody invents.
bool isOpenableUrl(const std::string& url) {
  if (url.empty() || url.size() > 2048) return false;

  // A UNC path (\\host\share) has no scheme and ShellExecute will happily
  // mount and run from it. Rejected before scheme parsing, because it never
  // reaches it.
  if (url.size() >= 2 && (url[0] == '\\' || url[0] == '/') &&
      url[0] == url[1]) {
    return false;
  }
  // A bare Windows drive path (C:\...) parses as scheme "c" under a naive
  // reader; reject single-letter schemes outright.
  auto colon = url.find(':');
  if (colon == std::string::npos || colon < 2) return false;

  std::string scheme = url.substr(0, colon);
  for (char& c : scheme) {
    if (!isAsciiAlpha(c) && !(c >= '0' && c <= '9') && c != '+' && c != '-' &&
        c != '.') {
      return false;
    }
    c = (char)std::tolower((unsigned char)c);
  }

  // The allowlist. `file` is deliberately ABSENT: it is the scheme that turns
  // "open a link" into "execute whatever is on disk" on Windows.
  static const char* kAllowed[] = {"http", "https", "mailto", "tel"};
  bool allowed = false;
  for (const char* s : kAllowed) {
    if (scheme == s) { allowed = true; break; }
  }
  if (!allowed) return false;

  // No control characters, no quotes, and none of the characters a shell or
  // ShellExecute treats structurally. A legitimate URL needs none of these
  // unescaped.
  for (unsigned char c : url) {
    if (c < 0x20 || c == 0x7f) return false;
    if (std::string("\"'`$|&;<>^%\\ ").find((char)c) != std::string::npos) {
      return false;
    }
  }
  return true;
}

int runOpenUrlSelfTest() {
  struct Case { const char* url; bool expect; };
  // Both directions: a predicate that only ever rejects is as useless as one
  // that only ever accepts, and a table of only-hostile inputs cannot tell
  // them apart.
  static const Case kCases[] = {
      {"https://example.com", true},
      {"http://example.com/a/b?c=d#e", true},
      {"mailto:someone@example.com", true},
      {"tel:+15551234567", true},
      // --- must be refused ---
      {"file:///etc/passwd", false},
      {"file://C:/Windows/System32/cmd.exe", false},
      {"\\\\attacker\\share\\evil.bat", false},
      {"//attacker/share/evil.bat", false},
      {"C:\\Windows\\System32\\cmd.exe", false},
      {"cmd.exe", false},
      {"https://example.com/a\" & calc.exe & \"", false},
      {"https://example.com/`whoami`", false},
      {"https://example.com/a|b", false},
      {"https://example.com/a;b", false},
      {"javascript:alert(1)", false},
      {"data:text/html,<script>1</script>", false},
      {"", false},
  };
  int failures = 0;
  for (const auto& c : kCases) {
    bool got = isOpenableUrl(c.url);
    if (got != c.expect) {
      ++failures;
      std::printf("  OPENURL MISMATCH %-44s expected=%s got=%s\n", c.url,
                  c.expect ? "open" : "refuse", got ? "open" : "refuse");
    }
  }
  int total = (int)(sizeof(kCases) / sizeof(kCases[0]));
  if (failures) {
    std::printf("OPENURL_FAIL (%d cases, %d failures)\n", total, failures);
    return 1;
  }
  std::printf("OPENURL_PASS (%d cases, 0 failures)\n", total);
  return 0;
}

// ---------------------------------------------------------------------------

void AlertManagerModule::alertWithArgs(jsi::Runtime& rt, jsi::Object args,
                                       jsi::Function callback) {
  std::string title;
  if (auto v = args.getProperty(rt, "title"); v.isString()) {
    title = v.asString(rt).utf8(rt);
  }
  record_->record(title);
  std::printf("rn-impeller: alert=%s\n", title.c_str());
  std::fflush(stdout);

  // Invoke with button index 0. Doing NOTHING would leave the promise inside
  // Alert.js pending forever, which presents as a hang rather than as a
  // missing feature — a strictly worse failure than an honest default.
  callback.call(rt, jsi::Value(0.0), jsi::String::createFromAscii(rt, ""));
}

// ---------------------------------------------------------------------------

jsi::Value LinkingManagerModule::getInitialURL(jsi::Runtime& rt) {
  if (!initialUrl_ || initialUrl_->empty()) {
    return resolvedPromise(rt, jsi::Value::null());
  }
  return resolvedPromise(rt,
                         jsi::String::createFromUtf8(rt, *initialUrl_));
}

jsi::Value LinkingManagerModule::canOpenURL(jsi::Runtime& rt, jsi::String url) {
  return resolvedPromise(rt, jsi::Value(isOpenableUrl(url.utf8(rt))));
}

jsi::Value LinkingManagerModule::openURL(jsi::Runtime& rt, jsi::String url) {
  std::string target = url.utf8(rt);
  if (!isOpenableUrl(target)) {
    // Refusal must be visible. A silently-swallowed openURL is the failure
    // mode where a user reports "the link does nothing" and no log says why.
    std::fprintf(stderr, "rn-impeller: openURL REFUSED (not an openable URL): %s\n",
                 target.c_str());
    std::fflush(stderr);
    return resolvedPromise(rt, jsi::Value(false));
  }
  std::printf("rn-impeller: openURL=%s\n", target.c_str());
  std::fflush(stdout);

#ifdef _WIN32
  // ShellExecuteW, but ONLY behind isOpenableUrl above — see the long comment
  // on that predicate. ShellExecute resolves its argument the way the shell
  // would, so it is a launcher, not a URL opener; the allowlist is what makes
  // this call safe rather than the API itself.
  //
  // `nullptr` verb (not L"open"): the default verb is what a user's browser
  // registration actually binds, and an explicit L"open" fails on schemes whose
  // registered verb differs. SW_SHOWNORMAL so a browser being launched cold
  // comes up visible rather than as a background process nobody can see.
  std::wstring wide;
  {
    // MultiByteToWideChar with CP_UTF8: the URL arrived as UTF-8 from JS, and
    // the ANSI ShellExecuteA would mangle every non-ASCII character in an IDN
    // or a percent-decoded path.
    int need = ::MultiByteToWideChar(CP_UTF8, 0, target.c_str(), -1, nullptr, 0);
    if (need > 0) {
      wide.resize((size_t)need - 1);
      ::MultiByteToWideChar(CP_UTF8, 0, target.c_str(), -1, wide.data(), need);
    }
  }
  // ShellExecuteW returns an HINSTANCE-shaped error code; > 32 means success.
  // Anything else is a real failure and must not be reported to JS as `true`.
  HINSTANCE rc = ::ShellExecuteW(nullptr, nullptr, wide.c_str(), nullptr,
                                 nullptr, SW_SHOWNORMAL);
  if ((INT_PTR)rc <= 32) {
    std::fprintf(stderr, "rn-impeller: openURL FAILED (ShellExecuteW=%lld): %s\n",
                 (long long)(INT_PTR)rc, target.c_str());
    std::fflush(stderr);
    return resolvedPromise(rt, jsi::Value(false));
  }
#else
  // fork+exec, never system(): system() runs /bin/sh -c and would reintroduce
  // exactly the shell interpretation the predicate exists to prevent.
  pid_t pid = fork();
  if (pid == 0) {
    execlp("xdg-open", "xdg-open", target.c_str(), (char*)nullptr);
    _exit(127);
  }
  // Do not wait: xdg-open can block for as long as the browser takes to start.
#endif
  return resolvedPromise(rt, jsi::Value(true));
}

jsi::Value LinkingManagerModule::openSettings(jsi::Runtime& rt) {
  // A desktop app has no OS settings page for itself. Honest no-op, and the
  // promise still settles so an awaiting caller proceeds.
  return resolvedPromise(rt, jsi::Value::undefined());
}

}  // namespace rni
