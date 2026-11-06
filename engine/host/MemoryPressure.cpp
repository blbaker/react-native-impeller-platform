#include "host/MemoryPressure.h"

#include "fabric/ImageStore.h"

#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#elif defined(_WIN32)
#include <windows.h>

#include <thread>
#elif defined(__linux__)
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

#include "base/Trace.h"
#endif

namespace rni::memorypressure {

#if defined(__linux__)
namespace {

// Before Linux 6.5, writing a trigger needs CAP_SYS_RESOURCE (psi_open returns EPERM), and the
// engine falls back to sampling (StartPsiPoll). From 6.5 an unprivileged writer may set a trigger
// only when the window is a multiple of 2 s, so the default window is 2 s.
constexpr const char* kPsiPath = "/proc/pressure/memory";
constexpr const char* kDefaultTrigger = "some 100000 2000000";

// Microseconds stalled since boot on the `kind` line ("some" or "full"), or -1.
long long StallTotalUs(const std::string& kind) {
  FILE* f = std::fopen(kPsiPath, "r");
  if (!f) return -1;
  char line[256];
  long long total = -1;
  while (std::fgets(line, sizeof line, f)) {
    const char* t = std::strstr(line, "total=");
    if (t && std::strncmp(line, kind.c_str(), kind.size()) == 0) total = std::atoll(t + 6);
  }
  std::fclose(f);
  return total;
}

// The fallback when psi_open refuses the trigger with EPERM (no CAP_SYS_RESOURCE before 6.5).
// Reading the file needs no capability, so sample it every 2 s and purge when the stall since the
// last sample reaches the trigger's threshold: the same purge and low_memory line as the trigger.
constexpr int kPollIntervalMs = 2000;

void StartPsiPoll(const std::string& trigger) {
  char kind[8] = "";
  unsigned long long thresholdUs = 0, windowUs = 0;
  // The kernel never saw this trigger (open failed first), so check it the way psi_trigger_create does.
  const bool valid = std::sscanf(trigger.c_str(), "%7s %llu %llu", kind, &thresholdUs, &windowUs) == 3 &&
                     (std::strcmp(kind, "some") == 0 || std::strcmp(kind, "full") == 0) && thresholdUs > 0 &&
                     thresholdUs <= windowUs;
  errno = 0;
  const long long first = valid ? StallTotalUs(kind) : -1;
  if (first < 0) {
    std::printf("rn-impeller: memory_pressure source=psi-poll armed=0 trigger=\"%s\" reason=%s errno=%d\n",
                trigger.c_str(), valid ? "unreadable" : "bad-trigger", errno);
    std::fflush(stdout);
    return;
  }
  std::printf("rn-impeller: memory_pressure source=psi-poll armed=1 interval_ms=%d kind=%s threshold_us=%llu path=%s\n",
              kPollIntervalMs, kind, thresholdUs, kPsiPath);
  std::fflush(stdout);
  std::thread([kind = std::string(kind), thresholdUs, last = first]() mutable {
    rni::trace::SetThreadName("rni-mem-psi");  // same name as the trigger thread; only one ever runs
    int event = 0;
    for (;;) {
      std::this_thread::sleep_for(std::chrono::milliseconds(kPollIntervalMs));
      errno = 0;
      const long long now = StallTotalUs(kind);
      if (now < 0) {
        std::printf("rn-impeller: memory_pressure source=psi-poll stopped errno=%d\n", errno);
        std::fflush(stdout);
        return;
      }
      const long long stall = now - last;
      last = now;
      if (stall < (long long)thresholdUs) continue;  // quiet samples log nothing: one every 2 s forever
      std::printf("rn-impeller: memory_pressure source=psi-poll event=%d stall_us=%lld threshold_us=%llu action=purge\n",
                  ++event, stall, thresholdUs);
      std::fflush(stdout);
      rni::image::HandleLowMemory("linux-psi");
    }
  }).detach();
}

void StartPsi() {
  const char* env = std::getenv("RNI_MEM_PSI");
  if (env && (std::strcmp(env, "off") == 0 || std::strcmp(env, "0") == 0)) {
    std::printf("rn-impeller: memory_pressure source=psi armed=0 reason=RNI_MEM_PSI=off\n");
    std::fflush(stdout);
    return;
  }
  const std::string trigger = (env && *env) ? env : kDefaultTrigger;
  const int fd = open(kPsiPath, O_RDWR | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0 || write(fd, trigger.c_str(), trigger.size() + 1) < 0) {
    const int err = errno;
    std::printf("rn-impeller: memory_pressure source=psi armed=0 trigger=\"%s\" step=%s errno=%d (%s)\n",
                trigger.c_str(), fd < 0 ? "open" : "write", err, std::strerror(err));
    std::fflush(stdout);
    if (fd >= 0) close(fd);
    if (fd < 0 && err == EPERM) StartPsiPoll(trigger);  // only a missing capability falls back
    return;
  }
  char kind[8] = "";
  unsigned long long thresholdUs = 0;
  std::sscanf(trigger.c_str(), "%7s %llu", kind, &thresholdUs);  // the kernel accepted it, so it parses
  const long long armedTotal = StallTotalUs(kind);
  std::printf("rn-impeller: memory_pressure source=psi armed=1 trigger=\"%s\" path=%s\n", trigger.c_str(),
              kPsiPath);
  std::fflush(stdout);
  std::thread([fd, kind = std::string(kind), thresholdUs, since = armedTotal]() mutable {
    // Named first: a thread inherits its creator's name, and gates count threads by name.
    rni::trace::SetThreadName("rni-mem-psi");
    pollfd p{fd, POLLPRI, 0};
    int event = 0;
    for (;;) {
      const int n = poll(&p, 1, -1);
      if (n < 0 && errno == EINTR) continue;
      if (n < 0 || (p.revents & (POLLERR | POLLNVAL))) {
        std::printf("rn-impeller: memory_pressure source=psi stopped errno=%d revents=%d\n", n < 0 ? errno : 0,
                    (int)p.revents);
        std::fflush(stdout);
        close(fd);
        return;
      }
      if (!(p.revents & POLLPRI)) continue;
      // An unprivileged trigger (Linux 6.5+) starts its window from the stale real-time-poll total
      // (psi_trigger_create: group->total[PSI_POLL]), so it fires on the first stalls after arming
      // however small they are. An event only counts once the stall since the last purge reaches
      // the threshold. The kernel sends at most one event per window.
      const long long now = StallTotalUs(kind);
      const long long stall = (since >= 0 && now >= 0) ? now - since : -1;
      const bool purge = stall < 0 || (unsigned long long)stall >= thresholdUs;
      std::printf("rn-impeller: memory_pressure source=psi event=%d stall_us=%lld threshold_us=%llu action=%s\n",
                  ++event, stall, thresholdUs, purge ? "purge" : "skip");
      std::fflush(stdout);
      if (!purge) continue;
      since = now;
      rni::image::HandleLowMemory("linux-psi");
    }
  }).detach();
}

}  // namespace
#endif

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
#elif defined(__linux__)
  static bool started = false;
  if (started) return;
  started = true;
  StartPsi();
#endif
}

}  // namespace rni::memorypressure
