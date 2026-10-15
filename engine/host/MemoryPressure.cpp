#include "host/MemoryPressure.h"

#include "fabric/ImageStore.h"

#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#elif defined(_WIN32)
#include <windows.h>

#include <thread>
#endif

namespace rni::memorypressure {

void Start() {
#if defined(__APPLE__)
  static dispatch_source_t source = nullptr;
  if (source) return;
  source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                                  DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
                                  dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  if (!source) return;
  dispatch_source_set_event_handler_f(source, [](void*) { rni::image::HandleLowMemory("macos"); });
  dispatch_resume(source);
#elif defined(_WIN32)
  static bool started = false;
  if (started) return;
  HANDLE h = CreateMemoryResourceNotification(LowMemoryResourceNotification);
  if (!h) return;
  started = true;
  // The handle stays signalled while memory is low: purge once, then wait before looking again.
  std::thread([h] {
    for (;;) {
      WaitForSingleObject(h, INFINITE);
      rni::image::HandleLowMemory("windows");
      Sleep(10000);
    }
  }).detach();
#endif
}

}  // namespace rni::memorypressure
