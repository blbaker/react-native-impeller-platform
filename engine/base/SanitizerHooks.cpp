#include "base/SanitizerHooks.h"

#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#if defined(_WIN32)
#include <process.h>
#define getpid _getpid
#else
#include <unistd.h>
#endif
#include <vector>

namespace rni::sanitize {
namespace {

bool EnvOn(const char* name) {
  const char* v = std::getenv(name);
  return v != nullptr && std::strcmp(v, "1") == 0;
}

// noinline + volatile operands keep the optimizer from folding the defect away.
[[gnu::noinline]] int ReadPastEnd(const std::vector<int>& v) {
  volatile size_t i = v.size();
  return v.data()[i];
}

[[gnu::noinline]] int AddOne(int x) {
  volatile int one = 1;
  return x + one;
}

}  // namespace

void RunTestHooks() {
#if defined(RNI_SANITIZE_BUILD)
  std::printf("rn-impeller: sanitize_build=1 sanitizers=%s\n", RNI_SANITIZE_BUILD);
  std::fflush(stdout);
  // ci-sanitize.sh counts these stamps to prove each gate ran THIS binary.
  if (const char* dir = std::getenv("RNI_SANITIZE_STAMP_DIR")) {
    std::string path = std::string(dir) + "/run." + std::to_string(getpid());
    if (FILE* f = std::fopen(path.c_str(), "w")) std::fclose(f);
  }
#endif
  if (EnvOn("RNI_TEST_ASAN_OOB")) {
    std::vector<int> v(8, 7);
    std::printf("rn-impeller: test_asan_oob value=%d\n", ReadPastEnd(v));
    std::fflush(stdout);
  }
  if (EnvOn("RNI_TEST_LSAN_LEAK")) {
    // Unreachable once the volatile slot is cleared: LeakSanitizer must report it at exit.
    static int* volatile slot = nullptr;
    slot = new int[16]();
    std::printf("rn-impeller: test_lsan_leak first=%d\n", slot[0]);
    slot = nullptr;
  }
  if (EnvOn("RNI_TEST_UBSAN_OVERFLOW")) {
    volatile int max = INT_MAX;
    std::printf("rn-impeller: test_ubsan_overflow value=%d\n", AddOne(max));
    std::fflush(stdout);
  }
}

}  // namespace rni::sanitize
