#include "text/FontFamily.h"

#include <algorithm>
#include <cctype>
#include <map>
#include <mutex>
#include <vector>

#if defined(__linux__)
#include <dlfcn.h>
#elif defined(__APPLE__)
#include <CoreText/CoreText.h>
#endif

namespace rni {
namespace {

std::string Lower(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](unsigned char c) { return (char)std::tolower(c); });
  return s;
}

std::vector<std::string> SplitStack(const std::string& stack) {
  std::vector<std::string> out;
  size_t start = 0;
  while (start <= stack.size()) {
    size_t comma = stack.find(',', start);
    std::string part = stack.substr(
        start, comma == std::string::npos ? std::string::npos : comma - start);
    size_t b = part.find_first_not_of(" \t\"'");
    size_t e = part.find_last_not_of(" \t\"'");
    if (b != std::string::npos) out.push_back(part.substr(b, e - b + 1));
    if (comma == std::string::npos) break;
    start = comma + 1;
  }
  return out;
}

// "" when the name is not a generic family.
std::string GenericKind(const std::string& name) {
  const std::string n = Lower(name);
  if (n == "monospace" || n == "ui-monospace") return "monospace";
  if (n == "serif" || n == "ui-serif") return "serif";
  if (n == "sans-serif" || n == "system-ui" || n == "ui-sans-serif" ||
      n == "-apple-system" || n == "blinkmacsystemfont") {
    return "sans-serif";
  }
  return "";
}

#if defined(__linux__)
// fontconfig through dlopen: no link-time dependency, and a box without it
// just keeps the generic name (Impeller's own default face).
struct Fc {
  void* lib = nullptr;
  void* (*patCreate)() = nullptr;
  int (*addString)(void*, const char*, const unsigned char*) = nullptr;
  int (*subst)(void*, void*, int) = nullptr;
  void (*defSubst)(void*) = nullptr;
  void* (*match)(void*, void*, int*) = nullptr;
  int (*getString)(void*, const char*, int, unsigned char**) = nullptr;
  void (*patDestroy)(void*) = nullptr;
  int (*appDir)(void*, const unsigned char*) = nullptr;
  bool ok = false;
};

Fc& FcLib() {
  static Fc fc = [] {
    Fc f;
    f.lib = dlopen("libfontconfig.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!f.lib) return f;
    auto sym = [&](const char* n) { return dlsym(f.lib, n); };
    f.patCreate = (decltype(f.patCreate))sym("FcPatternCreate");
    f.addString = (decltype(f.addString))sym("FcPatternAddString");
    f.subst = (decltype(f.subst))sym("FcConfigSubstitute");
    f.defSubst = (decltype(f.defSubst))sym("FcDefaultSubstitute");
    f.match = (decltype(f.match))sym("FcFontMatch");
    f.getString = (decltype(f.getString))sym("FcPatternGetString");
    f.patDestroy = (decltype(f.patDestroy))sym("FcPatternDestroy");
    f.appDir = (decltype(f.appDir))sym("FcConfigAppFontAddDir");
    f.ok = f.patCreate && f.addString && f.subst && f.defSubst && f.match &&
           f.getString && f.patDestroy && f.appDir;
    return f;
  }();
  return fc;
}

// The family fontconfig would pick for `name` ("" when unavailable).
std::string FcMatchFamily(const std::string& name) {
  Fc& fc = FcLib();
  if (!fc.ok) return "";
  void* pat = fc.patCreate();
  if (!pat) return "";
  fc.addString(pat, "family", (const unsigned char*)name.c_str());
  fc.subst(nullptr, pat, 0);  // FcMatchPattern
  fc.defSubst(pat);
  int result = 0;
  void* best = fc.match(nullptr, pat, &result);
  std::string family;
  if (best) {
    unsigned char* s = nullptr;
    if (fc.getString(best, "family", 0, &s) == 0 && s) family = (const char*)s;
    fc.patDestroy(best);
  }
  fc.patDestroy(pat);
  return family;
}

std::string Generic(const std::string& kind) {
  std::string f = FcMatchFamily(kind);
  return f.empty() ? kind : f;
}

bool Exists(const std::string& name) {
  return Lower(FcMatchFamily(name)) == Lower(name);
}
#elif defined(__APPLE__)
std::string FromCf(CFStringRef s) {
  if (!s) return "";
  char buf[256];
  return CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8) ? buf : "";
}

// True when CoreText has an installed family of exactly this name (the name
// Impeller's CoreText font manager resolves); no fallback match counts.
bool Exists(const std::string& name) {
  CFStringRef fam = CFStringCreateWithCString(nullptr, name.c_str(),
                                              kCFStringEncodingUTF8);
  if (!fam) return false;
  const void* keys[] = {kCTFontFamilyNameAttribute};
  const void* vals[] = {fam};
  CFDictionaryRef attrs = CFDictionaryCreate(
      nullptr, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes(attrs);
  CFSetRef mandatory = CFSetCreate(nullptr, keys, 1, &kCFTypeSetCallBacks);
  CTFontDescriptorRef match =
      CTFontDescriptorCreateMatchingFontDescriptor(desc, mandatory);
  const bool ok = match != nullptr;
  if (match) CFRelease(match);
  CFRelease(mandatory);
  CFRelease(desc);
  CFRelease(attrs);
  CFRelease(fam);
  return ok;
}

// The user's fixed-pitch UI font, unless it is a hidden "."-prefixed family.
std::string UserFixedPitchFamily() {
  CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontUserFixedPitch, 0,
                                              nullptr);
  if (!f) return "";
  CFStringRef fam = CTFontCopyFamilyName(f);
  std::string out = FromCf(fam);
  if (fam) CFRelease(fam);
  CFRelease(f);
  return !out.empty() && out[0] != '.' ? out : "";
}

std::string Generic(const std::string& kind) {
  std::vector<std::string> picks;
  if (kind == "monospace") {
    picks = {UserFixedPitchFamily(), "Menlo", "Monaco", "Courier New"};
  } else if (kind == "serif") {
    picks = {"Times", "Times New Roman", "Georgia"};
  } else {
    picks = {"Helvetica", "Helvetica Neue", "Arial"};
  }
  for (const std::string& p : picks) {
    if (!p.empty() && Exists(p)) return p;
  }
  return kind;
}
#elif defined(_WIN32)
std::string Generic(const std::string& kind) {
  if (kind == "monospace") return "Consolas";
  if (kind == "serif") return "Times New Roman";
  return "Segoe UI";
}
bool Exists(const std::string&) { return true; }  // first entry wins
#else
std::string Generic(const std::string& kind) { return kind; }
bool Exists(const std::string&) { return true; }
#endif

}  // namespace

void NoteAppFontDir(const std::string& dir) {
#if defined(__linux__)
  Fc& fc = FcLib();
  if (fc.ok) fc.appDir(nullptr, (const unsigned char*)dir.c_str());
#else
  (void)dir;
#endif
}

std::string ResolveFontFamily(const std::string& stack) {
  if (stack.empty()) return stack;
  static std::mutex mu;
  static std::map<std::string, std::string> cache;
  std::lock_guard<std::mutex> lock(mu);
  auto hit = cache.find(stack);
  if (hit != cache.end()) return hit->second;

  const std::vector<std::string> names = SplitStack(stack);
  std::string chosen;
  for (size_t i = 0; i < names.size() && chosen.empty(); ++i) {
    const std::string kind = GenericKind(names[i]);
    if (!kind.empty()) chosen = Generic(kind);
    else if (names.size() == 1 || Exists(names[i])) chosen = names[i];
  }
  if (chosen.empty()) chosen = names.empty() ? stack : names.front();
  cache[stack] = chosen;
  return chosen;
}

}  // namespace rni
