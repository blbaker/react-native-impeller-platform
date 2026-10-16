// FP-50: runs the registered cases. `rni-scenegraph-tests [--list] [name-substring]`.
// Exit 0 only when every selected case passes; prints one PASS/FAIL line per case and a total time.
#include <chrono>
#include <cstdio>
#include <cstring>

#include "tests/TestHarness.h"

namespace rni::test {

namespace {
int gFailures = 0;
}  // namespace

std::vector<Case>& Registry() {
  static std::vector<Case> r;
  return r;
}

void Fail(const char* file, int line, const std::string& message) {
  ++gFailures;
  std::printf("  %s:%d: %s\n", file, line, message.c_str());
}

namespace {
std::string Line(const std::string& text, size_t n) {
  size_t pos = 0;
  for (size_t i = 0; i < n; ++i) {
    pos = text.find('\n', pos);
    if (pos == std::string::npos) return "<end>";
    ++pos;
  }
  const size_t end = text.find('\n', pos);
  return text.substr(pos, end == std::string::npos ? std::string::npos : end - pos);
}
}  // namespace

void ExpectText(const char* file, int line, const std::string& actual, const std::string& expected) {
  if (actual == expected) return;
  size_t n = 0;
  while (Line(actual, n) == Line(expected, n) && Line(actual, n) != "<end>") ++n;
  Fail(file, line, "ops differ at line " + std::to_string(n + 1) + "\n    expected: " + Line(expected, n) +
                       "\n    actual:   " + Line(actual, n) + "\n--- actual ---\n" + actual + "--- end ---");
}

void ExpectLinesInOrder(const char* file, int line, const std::string& haystack,
                        const std::vector<std::string>& needles) {
  size_t from = 0;
  for (const std::string& needle : needles) {
    const size_t at = haystack.find(needle, from);
    if (at == std::string::npos) {
      Fail(file, line, "missing (or out of order) '" + needle + "'\n--- actual ---\n" + haystack + "--- end ---");
      return;
    }
    from = at + needle.size();
  }
}

void ExpectAbsent(const char* file, int line, const std::string& haystack, const std::string& needle) {
  if (haystack.find(needle) != std::string::npos) {
    Fail(file, line, "unexpected '" + needle + "'\n--- actual ---\n" + haystack + "--- end ---");
  }
}

}  // namespace rni::test

int main(int argc, char** argv) {
  using namespace rni::test;
  const char* filter = nullptr;
  bool list = false;
  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--list")) list = true; else filter = argv[i];
  }
  const auto t0 = std::chrono::steady_clock::now();
  int ran = 0, failed = 0;
  for (const Case& c : Registry()) {
    if (filter && c.name.find(filter) == std::string::npos) continue;
    if (list) { std::printf("%s\n", c.name.c_str()); continue; }
    const int before = gFailures;
    c.body();
    ++ran;
    if (gFailures != before) ++failed;
    std::printf("%s %s\n", gFailures == before ? "PASS" : "FAIL", c.name.c_str());
  }
  if (list) return 0;
  const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  std::printf("rni-scenegraph-tests: %d cases, %d failed, %.0f ms\n", ran, failed, ms);
  if (ran == 0) return 2;  // a filter that matches nothing must not pass
  return failed == 0 ? 0 : 1;
}
