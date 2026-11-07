// darwin-onscreen-windows: watch the window-server windows a PID owns and
// report whether any was ever ON SCREEN. The darwin twin of
// tools/x11-viewable-windows.py, used by tools/ci-window-hidden.sh.
//
//   cc -O2 -o darwin-onscreen-windows tools/darwin-onscreen-windows.c \
//      -framework CoreGraphics -framework CoreFoundation
//   darwin-onscreen-windows <pid> <seconds> [--kill-on-screen]
//
// Prints one line and exits 0:
//   darwin_windows pid=<pid> found=<max windows seen> max_onscreen=<max on screen> samples=<n>
// --kill-on-screen SIGKILLs <pid> the first time one of its windows is on
// screen (and adds killed_on_screen=1), so a broken hidden mode is cut off
// within one 50 ms sample instead of sitting on the user's display.
// found=0 means the oracle never saw the engine's window at all, so the gate
// treats max_onscreen=0 next to it as no evidence. This reads the WINDOW
// SERVER (CGWindowListCopyWindowInfo, kCGWindowIsOnscreen), from outside the
// engine; the engine's own window_hidden line is AppKit's view of itself.
// Owner PID and on-screen state need no Screen Recording permission.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void scan(int pid, int* found, int* onscreen) {
  *found = *onscreen = 0;
  CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
  if (!list) return;
  for (CFIndex i = 0; i < CFArrayGetCount(list); ++i) {
    CFDictionaryRef w = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
    CFNumberRef owner = (CFNumberRef)CFDictionaryGetValue(w, kCGWindowOwnerPID);
    int p = 0;
    if (!owner || !CFNumberGetValue(owner, kCFNumberIntType, &p) || p != pid) continue;
    ++*found;
    CFBooleanRef on = (CFBooleanRef)CFDictionaryGetValue(w, kCGWindowIsOnscreen);
    if (on && CFBooleanGetValue(on)) ++*onscreen;
  }
  CFRelease(list);
}

int main(int argc, char** argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: darwin-onscreen-windows <pid> <seconds>\n");
    return 2;
  }
  const int pid = atoi(argv[1]);
  const double deadline = now_s() + atof(argv[2]);
  const int killOnScreen = argc > 3 && strcmp(argv[3], "--kill-on-screen") == 0;
  int maxFound = 0, maxOn = 0, samples = 0, killed = 0;
  while (now_s() < deadline && kill(pid, 0) == 0) {
    int f = 0, o = 0;
    scan(pid, &f, &o);
    if (f > maxFound) maxFound = f;
    if (o > maxOn) maxOn = o;
    ++samples;
    if (o > 0 && killOnScreen) {
      kill(pid, SIGKILL);
      killed = 1;
      break;
    }
    usleep(50000);
  }
  printf("darwin_windows pid=%d found=%d max_onscreen=%d samples=%d%s\n", pid, maxFound, maxOn,
         samples, killed ? " killed_on_screen=1" : "");
  return 0;
}
