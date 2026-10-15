// FP-04: make single-thread contracts of UNINSTRUMENTED libraries visible to
// ThreadSanitizer. libimpeller.so is prebuilt, so TSan never sees its internal
// reads/writes; a typography context used from two threads (impeller.h: "must
// be created, used, and collected on a single thread") would race silently.
// NoteExclusiveUse records a TSan write on the object at our call site, so
// two unordered uses report as a data race with both of our stacks. It is the
// TSan-visible form of Flutter's fml/memory/thread_checker.h. No-op otherwise.
#pragma once

#if defined(__has_feature)
#if __has_feature(thread_sanitizer)
#define RNI_TSAN 1
#endif
#endif
#if !defined(RNI_TSAN) && defined(__SANITIZE_THREAD__)
#define RNI_TSAN 1
#endif

#if defined(RNI_TSAN)
extern "C" void __tsan_write1(void* addr);
#endif

namespace rni::tsan {

[[gnu::always_inline]] inline void NoteExclusiveUse(const void* object) {
#if defined(RNI_TSAN)
  if (object != nullptr) __tsan_write1(const_cast<void*>(object));
#else
  (void)object;
#endif
}

}  // namespace rni::tsan
