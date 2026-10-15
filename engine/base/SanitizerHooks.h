// FP-03: env-gated defects that prove the ASan/UBSan build (RNI_SANITIZE) catches
// what it claims to. Mirrors Flutter's practice of keeping sanitizer canaries in
// the tested binary (testing/run_tests.py runs the real targets under ASan).
#pragma once

namespace rni::sanitize {

// Runs the deliberate defects, selected by environment variable:
//   RNI_TEST_ASAN_OOB=1      reads one element past a heap std::vector (ASan aborts)
//   RNI_TEST_UBSAN_OVERFLOW=1 adds 1 to INT_MAX in signed int (UBSan reports)
//   RNI_TEST_LSAN_LEAK=1     drops the only pointer to a heap block (LSan reports at exit)
// No-op when neither is set. Sanitized builds print `sanitize_build=1` so gates can
// prove the binary under test is the instrumented one.
void RunTestHooks();

}  // namespace rni::sanitize
