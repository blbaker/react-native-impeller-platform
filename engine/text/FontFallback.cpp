#include "text/FontFallback.h"
#include "base/TsanAnnotate.h"

#include "text/FontFamily.h"

#include <fstream>
#include <iterator>
#include <map>
#include <mutex>
#include <set>

#if defined(__linux__)
#include <dlfcn.h>
#endif

namespace rni {
namespace {

#if defined(__linux__)
struct Fc {
  void* (*patCreate)() = nullptr;
  int (*addString)(void*, const char*, const unsigned char*) = nullptr;
  int (*addBool)(void*, const char*, int) = nullptr;
  int (*addCharSet)(void*, const char*, void*) = nullptr;
  int (*subst)(void*, void*, int) = nullptr;
  void (*defSubst)(void*) = nullptr;
  void* (*match)(void*, void*, int*) = nullptr;
  int (*getString)(void*, const char*, int, unsigned char**) = nullptr;
  int (*getCharSet)(void*, const char*, int, void**) = nullptr;
  void (*patDestroy)(void*) = nullptr;
  void* (*csCreate)() = nullptr;
  int (*csAdd)(void*, uint32_t) = nullptr;
  int (*csHas)(void*, uint32_t) = nullptr;
  void (*csDestroy)(void*) = nullptr;
  bool ok = false;
};

Fc& FcSyms() {
  static Fc fc = [] {
    Fc f;
    void* lib = dlopen("libfontconfig.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!lib) return f;
    auto sym = [&](const char* n) { return dlsym(lib, n); };
#define RNI_FC(field, name) f.field = (decltype(f.field))sym(name)
    RNI_FC(patCreate, "FcPatternCreate");
    RNI_FC(addString, "FcPatternAddString");
    RNI_FC(addBool, "FcPatternAddBool");
    RNI_FC(addCharSet, "FcPatternAddCharSet");
    RNI_FC(subst, "FcConfigSubstitute");
    RNI_FC(defSubst, "FcDefaultSubstitute");
    RNI_FC(match, "FcFontMatch");
    RNI_FC(getString, "FcPatternGetString");
    RNI_FC(getCharSet, "FcPatternGetCharSet");
    RNI_FC(patDestroy, "FcPatternDestroy");
    RNI_FC(csCreate, "FcCharSetCreate");
    RNI_FC(csAdd, "FcCharSetAddChar");
    RNI_FC(csHas, "FcCharSetHasChar");
    RNI_FC(csDestroy, "FcCharSetDestroy");
#undef RNI_FC
    f.ok = f.patCreate && f.addString && f.addBool && f.addCharSet && f.subst &&
           f.defSubst && f.match && f.getString && f.getCharSet &&
           f.patDestroy && f.csCreate && f.csAdd && f.csHas && f.csDestroy;
    return f;
  }();
  return fc;
}

struct FontBlob {
  std::vector<uint8_t> bytes;
  ImpellerMapping mapping{};
};
void ReleaseBlob(void* u) { delete static_cast<FontBlob*>(u); }

std::mutex gMu;

// The matched pattern is kept for the process lifetime: its charset is borrowed.
void* gPrimaryCharset(Fc& fc, const std::string& family) {
  static std::map<std::string, void*> cache;
  auto hit = cache.find(family);
  if (hit != cache.end()) return hit->second;
  void* cs = nullptr;
  void* pat = fc.patCreate();
  fc.addString(pat, "family", (const unsigned char*)family.c_str());
  fc.subst(nullptr, pat, 0);
  fc.defSubst(pat);
  int result = 0;
  void* best = fc.match(nullptr, pat, &result);
  fc.patDestroy(pat);
  if (best) fc.getCharSet(best, "charset", 0, &cs);
  return cache[family] = cs;
}

// Family of a face that covers `cp`, registered with Impeller ("" = none).
std::string FallbackFor(ImpellerTypographyContext typography, uint32_t cp) {
  static std::map<uint32_t, std::string> byCp;
  static std::set<std::string> registered;
  auto hit = byCp.find(cp);
  if (hit != byCp.end()) return hit->second;
  Fc& fc = FcSyms();
  std::string family;
  void* cs = fc.csCreate();
  fc.csAdd(cs, cp);
  void* pat = fc.patCreate();
  fc.addCharSet(pat, "charset", cs);
  if (cp >= 0x1F000) fc.addBool(pat, "color", 1);
  fc.subst(nullptr, pat, 0);
  fc.defSubst(pat);
  int result = 0;
  void* best = fc.match(nullptr, pat, &result);
  fc.patDestroy(pat);
  fc.csDestroy(cs);
  if (best) {
    void* bestCs = nullptr;
    unsigned char* file = nullptr;
    unsigned char* fam = nullptr;
    if (fc.getCharSet(best, "charset", 0, &bestCs) == 0 && bestCs &&
        fc.csHas(bestCs, cp) && fc.getString(best, "file", 0, &file) == 0 &&
        fc.getString(best, "family", 0, &fam) == 0 && file && fam) {
      const std::string path = (const char*)file;
      // The file's own family name is what Impeller indexes it under.
      family = (const char*)fam;
      if (!registered.count(path)) {
        registered.insert(path);
        std::ifstream in(path, std::ios::binary);
        auto* blob = new FontBlob();
        blob->bytes.assign(std::istreambuf_iterator<char>(in),
                           std::istreambuf_iterator<char>());
        blob->mapping.data = blob->bytes.data();
        blob->mapping.length = blob->bytes.size();
        blob->mapping.on_release = &ReleaseBlob;
        // Ownership passes to Impeller, success or not.
        if (blob->bytes.empty() ||
            !ImpellerTypographyContextRegisterFont(typography, &blob->mapping,
                                                   blob, nullptr)) {
          family.clear();
        }
      }
    }
    fc.patDestroy(best);
  }
  return byCp[cp] = family;
}

uint32_t Decode(const std::string& s, size_t& i) {
  const unsigned char c = (unsigned char)s[i];
  int n = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 1;
  if (i + n > s.size()) n = 1;
  uint32_t cp = n == 1 ? c : c & (0xFF >> (n + 1));
  for (int k = 1; k < n; ++k) cp = (cp << 6) | ((unsigned char)s[i + k] & 0x3F);
  i += n;
  return cp;
}

// Marks, joiners and variation selectors stay with the glyph before them.
bool Sticks(uint32_t cp) {
  return cp == 0x200D || cp == 0x200C || (cp >= 0xFE00 && cp <= 0xFE0F) ||
         (cp >= 0x300 && cp <= 0x36F) || (cp >= 0x610 && cp <= 0x61A) ||
         (cp >= 0x64B && cp <= 0x65F) || (cp >= 0x1F3FB && cp <= 0x1F3FF) ||
         (cp >= 0xE0020 && cp <= 0xE007F);
}
#endif

}  // namespace

std::vector<FontSegment> SplitFontFallback(ImpellerTypographyContext typography,
                                           const std::string& primary,
                                           const std::string& text) {
  rni::tsan::NoteExclusiveUse(typography);  // FP-04: impeller.h typography contexts are single-thread
#if defined(__linux__)
  bool ascii = true;
  for (unsigned char c : text) ascii = ascii && c < 0x80;
  Fc& fc = FcSyms();
  if (!ascii && fc.ok && typography != nullptr) {
    std::lock_guard<std::mutex> lock(gMu);
    // Impeller's built-in default face is not one fontconfig knows: assume it
    // covers Latin plus common punctuation only.
    void* cov = primary.empty() ? nullptr : gPrimaryCharset(fc, primary);
    std::vector<FontSegment> out;
    bool any = false;
    std::string prevFamily;
    for (size_t i = 0; i < text.size();) {
      const size_t start = i;
      const uint32_t cp = Decode(text, i);
      std::string fam = prevFamily;  // stickies and spaces follow the previous glyph
      if (out.empty() || !(Sticks(cp) || cp == ' ')) {
        const bool covered = cov ? (cp < 0x80 || fc.csHas(cov, cp))
                                 : (cp < 0x250 || (cp >= 0x2010 && cp <= 0x2027));
        fam = covered ? "" : FallbackFor(typography, cp);
      }
      any = any || !fam.empty();
      if (out.empty() || out.back().family != fam) out.push_back({fam, ""});
      out.back().text.append(text, start, i - start);
      prevFamily = fam;
    }
    if (any) return out;
  }
#else
  (void)typography;
  (void)primary;
#endif
  return {FontSegment{"", text}};
}

void ApplySegmentFamily(ImpellerParagraphStyle style, const std::string& primary,
                        const FontSegment& seg, bool singleSegment) {
  std::string fam = seg.family;
  if (fam.empty()) fam = primary;
  if (fam.empty() && !singleSegment) fam = ResolveFontFamily("sans-serif");
  if (!fam.empty()) ImpellerParagraphStyleSetFontFamily(style, fam.c_str());
}

}  // namespace rni
