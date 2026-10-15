// FP-52: one binary, a target switch. Model: Skia's fuzz/FuzzMain.cpp (`--type`),
// with libFuzzer's driver (LLVMFuzzerRunDriver) instead of a fixed input file.
// Flutter's pin has no fuzzers of its own (build/secondary/testing/libfuzzer/
// fuzzer_test.gni is a no-op stub), so Skia's oss_fuzz targets are the model.
#include "fuzz/Fuzz.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

extern "C" int LLVMFuzzerRunDriver(int* argc, char*** argv,
                                   int (*cb)(const uint8_t* data, size_t size));

namespace rni::fuzz {

namespace {

struct Entry {
  const char* name;
  int (*fn)(const uint8_t*, size_t);
};

constexpr Entry kTargets[] = {
    {"svg-path", SvgPath}, {"svg-dash", SvgDash}, {"image-decode", ImageDecode},
    {"props", Props},      {"scene", Scene},
};

}  // namespace

bool Requested(int argc, char** argv) {
  return (argc > 1 && std::strcmp(argv[1], "--fuzz") == 0) || std::getenv("RNI_FUZZ_TARGET");
}

int Main(int argc, char** argv) {
  // `--fuzz <target>` names it; libFuzzer's -merge/-fork children re-exec argv[0]
  // with only libFuzzer flags, so the target also travels in RNI_FUZZ_TARGET.
  const bool flag = argc > 1 && std::strcmp(argv[1], "--fuzz") == 0;
  const char* env = std::getenv("RNI_FUZZ_TARGET");
  const char* name = flag ? (argc > 2 ? argv[2] : "") : (env ? env : "");
  const int first = flag ? 3 : 1;
  for (const Entry& e : kTargets) {
    if (std::strcmp(e.name, name) != 0) continue;
    setenv("RNI_FUZZ_TARGET", e.name, 1);
    std::printf("fuzz_target=%s\n", e.name);
    std::fflush(stdout);
    // libFuzzer sees argv[0] followed by everything after the target name.
    std::vector<char*> args{argv[0]};
    for (int i = first; i < argc; ++i) args.push_back(argv[i]);
    args.push_back(nullptr);
    int n = (int)args.size() - 1;
    char** v = args.data();
    return LLVMFuzzerRunDriver(&n, &v, e.fn);
  }
  std::fprintf(stderr, "rn-impeller --fuzz: unknown target '%s'; targets:", name);
  for (const Entry& e : kTargets) std::fprintf(stderr, " %s", e.name);
  std::fprintf(stderr, "\n");
  return 64;
}

}  // namespace rni::fuzz
