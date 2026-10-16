#pragma once
// FP-50: a minimal test registry for rni-scenegraph-tests (no gtest in the tree; CTest only needs
// an exit code). Model: Flutter's TEST_P suites, which assert recorded ops rather than pixels.
#include <functional>
#include <string>
#include <vector>

namespace rni::test {

struct Case {
  std::string name;
  std::function<void()> body;
};
std::vector<Case>& Registry();

struct Registrar {
  Registrar(const char* name, std::function<void()> body) { Registry().push_back({name, std::move(body)}); }
};

// Records the failure and returns; the case keeps running so one run lists every mismatch.
void Fail(const char* file, int line, const std::string& message);

// Exact comparison of two multi-line texts; on mismatch prints both with the first differing line.
void ExpectText(const char* file, int line, const std::string& actual, const std::string& expected);
// Every needle must appear, in order, as a line fragment of `haystack`.
void ExpectLinesInOrder(const char* file, int line, const std::string& haystack,
                        const std::vector<std::string>& needles);
// The needle must not appear anywhere in `haystack`.
void ExpectAbsent(const char* file, int line, const std::string& haystack, const std::string& needle);

}  // namespace rni::test

#define RNI_TEST(name)                                              \
  static void name();                                               \
  static ::rni::test::Registrar registrar_##name(#name, &name);     \
  static void name()

#define EXPECT_TEXT(actual, expected) ::rni::test::ExpectText(__FILE__, __LINE__, (actual), (expected))
#define EXPECT_ORDER(haystack, ...) \
  ::rni::test::ExpectLinesInOrder(__FILE__, __LINE__, (haystack), std::vector<std::string>{__VA_ARGS__})
#define EXPECT_ABSENT(haystack, needle) ::rni::test::ExpectAbsent(__FILE__, __LINE__, (haystack), (needle))
#define EXPECT_TRUE(cond) \
  do { if (!(cond)) ::rni::test::Fail(__FILE__, __LINE__, "expected true: " #cond); } while (0)
