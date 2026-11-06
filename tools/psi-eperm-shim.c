// LD_PRELOAD shim for tools/ci-mem-psi.sh (nocap arms): makes a write-mode open of
// /proc/pressure/memory fail with EPERM, the way psi_open answers a process without
// CAP_SYS_RESOURCE before Linux 6.5. Linux 6.5+ lets an unprivileged process set a 2 s trigger,
// so on a dev box the real EPERM never happens. Read-only opens pass through.
// Prints one line to stderr per refusal so the gate can prove the EPERM came from here.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static const char kPsi[] = "/proc/pressure/memory";

static int refuse(const char* path, int flags) {
  if (!path || strcmp(path, kPsi) != 0 || (flags & O_ACCMODE) == O_RDONLY) return 0;
  fprintf(stderr, "psi-eperm-shim: open(%s, flags=0x%x) -> EPERM\n", path, flags);
  errno = EPERM;
  return 1;
}

#define SHIM_OPEN(name)                                                            \
  int name(const char* path, int flags, ...) {                                     \
    mode_t mode = 0;                                                               \
    if (flags & (O_CREAT | O_TMPFILE)) {                                           \
      va_list ap;                                                                  \
      va_start(ap, flags);                                                         \
      mode = va_arg(ap, mode_t);                                                   \
      va_end(ap);                                                                  \
    }                                                                              \
    if (refuse(path, flags)) return -1;                                            \
    int (*real)(const char*, int, ...) = (int (*)(const char*, int, ...))dlsym(RTLD_NEXT, #name); \
    return real(path, flags, mode);                                                \
  }

#define SHIM_OPENAT(name)                                                          \
  int name(int dirfd, const char* path, int flags, ...) {                          \
    mode_t mode = 0;                                                               \
    if (flags & (O_CREAT | O_TMPFILE)) {                                           \
      va_list ap;                                                                  \
      va_start(ap, flags);                                                         \
      mode = va_arg(ap, mode_t);                                                   \
      va_end(ap);                                                                  \
    }                                                                              \
    if (refuse(path, flags)) return -1;                                            \
    int (*real)(int, const char*, int, ...) = (int (*)(int, const char*, int, ...))dlsym(RTLD_NEXT, #name); \
    return real(dirfd, path, flags, mode);                                         \
  }

SHIM_OPEN(open)
SHIM_OPEN(open64)
SHIM_OPENAT(openat)
SHIM_OPENAT(openat64)

// _FORTIFY_SOURCE builds call these instead of open().
int __open_2(const char* path, int flags) {
  if (refuse(path, flags)) return -1;
  int (*real)(const char*, int) = (int (*)(const char*, int))dlsym(RTLD_NEXT, "__open_2");
  return real(path, flags);
}
int __open64_2(const char* path, int flags) {
  if (refuse(path, flags)) return -1;
  int (*real)(const char*, int) = (int (*)(const char*, int))dlsym(RTLD_NEXT, "__open64_2");
  return real(path, flags);
}
