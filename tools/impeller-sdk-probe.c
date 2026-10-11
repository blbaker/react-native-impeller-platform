// Probe for the SC-32 custom Impeller SDK (tools/ci-impeller-sdk-custom.sh).
// Lays out paragraphs on the CPU only (no GPU context) and prints key=value
// measurements the gate judges. Usage: impeller-sdk-probe <font.ttf>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "impeller.h"

#ifndef IMPELLER_RNI_TEXT_EXTENSIONS
#error "not the react-native-impeller custom SDK (IMPELLER_RNI_TEXT_EXTENSIONS missing)"
#endif

static ImpellerTypographyContext gTypo;

typedef struct Style {
  float letter;
  float word;
  const char* tag;  // OpenType feature tag or NULL
  int value;
  int clearAfter;       // set the feature, then ClearFontFeatures
} Style;

static ImpellerParagraphStyle MakeStyle(const Style* s) {
  ImpellerParagraphStyle ps = ImpellerParagraphStyleNew();
  ImpellerParagraphStyleSetFontFamily(ps, "RniProbe");
  ImpellerParagraphStyleSetFontSize(ps, 20.0f);
  if (s) {
    if (s->letter != 0) ImpellerParagraphStyleSetLetterSpacing(ps, s->letter);
    if (s->word != 0) ImpellerParagraphStyleSetWordSpacing(ps, s->word);
    if (s->tag) ImpellerParagraphStyleSetFontFeature(ps, s->tag, s->value);
    if (s->clearAfter) ImpellerParagraphStyleClearFontFeatures(ps);
  }
  return ps;
}

static void AddText(ImpellerParagraphBuilder b, const char* text) {
  ImpellerParagraphBuilderAddText(b, (const uint8_t*)text, (uint32_t)strlen(text));
}

static float Width(const char* text, const Style* s) {
  ImpellerParagraphStyle ps = MakeStyle(s);
  ImpellerParagraphBuilder b = ImpellerParagraphBuilderNew(gTypo);
  ImpellerParagraphBuilderPushStyle(b, ps);
  AddText(b, text);
  ImpellerParagraph p = ImpellerParagraphBuilderBuildParagraphNew(b, 1000.0f);
  float w = ImpellerParagraphGetMaxIntrinsicWidth(p);
  ImpellerParagraphRelease(p);
  ImpellerParagraphBuilderRelease(b);
  ImpellerParagraphStyleRelease(ps);
  return w;
}

// "AB" [placeholder] "CD"; prints the placeholder box read back after layout.
static void Placeholder(const char* name, ImpellerPlaceholderAlignment align) {
  ImpellerParagraphStyle ps = MakeStyle(NULL);
  ImpellerParagraphBuilder b = ImpellerParagraphBuilderNew(gTypo);
  ImpellerParagraphBuilderPushStyle(b, ps);
  AddText(b, "AB");
  ImpellerParagraphBuilderAddPlaceholder(b, 14.0f, 14.0f, align, 10.0f);
  AddText(b, "CD");
  ImpellerParagraph p = ImpellerParagraphBuilderBuildParagraphNew(b, 1000.0f);
  ImpellerRect r[2];
  memset(r, 0, sizeof(r));
  uint32_t n = ImpellerParagraphGetPlaceholderRects(p, r, 2);
  printf("%s_count=%u\n%s_x=%.3f\n%s_y=%.3f\n%s_w=%.3f\n%s_h=%.3f\n", name, n,
         name, r[0].x, name, r[0].y, name, r[0].width, name, r[0].height);
  printf("%s_width=%.3f\n%s_baseline=%.3f\n", name,
         ImpellerParagraphGetMaxIntrinsicWidth(p), name,
         ImpellerParagraphGetAlphabeticBaseline(p));
  printf("%s_count_null=%u\n", name, ImpellerParagraphGetPlaceholderRects(p, NULL, 0));
  ImpellerParagraphRelease(p);
  ImpellerParagraphBuilderRelease(b);
  ImpellerParagraphStyleRelease(ps);
}

static void* ReadFile(const char* path, size_t* len) {
  FILE* f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  void* data = malloc((size_t)n);
  if (fread(data, 1, (size_t)n, f) != (size_t)n) { free(data); data = NULL; }
  fclose(f);
  *len = (size_t)n;
  return data;
}

static void FreeData(void* user) { free(user); }

int main(int argc, char** argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s <font.ttf>\n", argv[0]); return 2; }
  size_t len = 0;
  void* font = ReadFile(argv[1], &len);
  if (!font) { fprintf(stderr, "cannot read %s\n", argv[1]); return 2; }
  gTypo = ImpellerTypographyContextNew();
  ImpellerMapping m = {(const uint8_t*)font, len, FreeData};
  if (!gTypo || !ImpellerTypographyContextRegisterFont(gTypo, &m, font, "RniProbe")) {
    fprintf(stderr, "font registration failed\n");
    return 2;
  }

  Style ls8 = {8.0f, 0, NULL, 0, 0}, ws10 = {0, 10.0f, NULL, 0, 0};
  printf("iiii_ls0=%.3f\niiii_ls8=%.3f\n", Width("IIII", NULL), Width("IIII", &ls8));
  printf("words_ws0=%.3f\nwords_ws10=%.3f\n", Width("a b c", NULL), Width("a b c", &ws10));

  Style tnum = {0, 0, "tnum", 1, 0}, pnum = {0, 0, "pnum", 1, 0};
  printf("n1111_pnum=%.3f\nn0000_pnum=%.3f\n", Width("1111", &pnum), Width("0000", &pnum));
  printf("n1111_tnum=%.3f\nn0000_tnum=%.3f\n", Width("1111", &tnum), Width("0000", &tnum));

  Style smcp = {0, 0, "smcp", 1, 0}, cleared = {0, 0, "smcp", 1, 1},
        badtag = {0, 0, "smc", 1, 0};
  printf("abc=%.3f\nabc_smcp=%.3f\nabc_cleared=%.3f\nabc_badtag=%.3f\n",
         Width("abc", NULL), Width("abc", &smcp), Width("abc", &cleared),
         Width("abc", &badtag));

  printf("ab=%.3f\nabcd=%.3f\n", Width("AB", NULL), Width("ABCD", NULL));
  Placeholder("ph_base", kImpellerPlaceholderAlignmentBaseline);
  Placeholder("ph_top", kImpellerPlaceholderAlignmentTop);
  printf("PROBE_DONE\n");
  ImpellerTypographyContextRelease(gTypo);
  return 0;
}
