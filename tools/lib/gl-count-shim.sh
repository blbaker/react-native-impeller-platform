#!/usr/bin/env bash
# FP-14: an LD_PRELOAD GL proc-table shim that counts GL calls per thread.
#   source tools/lib/gl-count-shim.sh; gl_shim_build <rn-impeller> <outdir>
# -> <outdir>/libglcount.so (linux x86_64 only; returns 1 elsewhere).
#
# Every GL entry point the process can reach goes through a trampoline that
# adds 1 to a thread-local counter and tail-jumps to the real function, so no
# signature is needed:
#   * gl* the binary imports directly (nm -D) are defined by the shim and bound
#     to libGLESv2 with dlsym(RTLD_NEXT) at load;
#   * gl* resolved at run time (Impeller's whole ProcTableGLES and GLFW's
#     loader, through eglGetProcAddress or dlsym on the EGL/GLES handles) get a
#     trampoline slot instead of the real pointer.
# Exports rni_gl_shim_thread_calls() (this thread's count), which
# engine/host/RecordNoGl.cpp reads around RECORD and RASTER. At exit it prints
# `gl_shim direct=N proc_slots=K overflow=0` on stderr.
gl_shim_build() {
  local bin="$1" out="$2"
  [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || return 1
  mkdir -p "$out"
  nm -D --undefined-only "$bin" | awk '{print $NF}' | sed 's/@.*//' | grep -E '^gl[A-Z]' | sort -u > "$out/direct.txt"
  python3 - "$out" <<'PY'
import sys
out = sys.argv[1]
names = [l.strip() for l in open(out + "/direct.txt") if l.strip()]
NPROC = 4096
asm = [".text"]
def tramp(sym, table, i, glob):
    if glob:
        asm.append(".globl %s" % sym)
    else:
        asm.append(".hidden %s" % sym)
        asm.append(".globl %s" % sym)
    asm.extend([".type %s,@function" % sym, "%s:" % sym,
            "  movq rni_gl_tls_calls@gottpoff(%rip), %r11",
            "  addq $1, %fs:(%r11)",
            "  jmp *(%s+%d)(%%rip)" % (table, 8 * i)])
for i, n in enumerate(names):
    tramp(n, "rni_direct_real", i, True)
for i in range(NPROC):
    tramp("rni_tramp_%d" % i, "rni_proc_real", i, False)
asm.append('.section .note.GNU-stack,"",@progbits')
open(out + "/tramps.S", "w").write("\n".join(asm) + "\n")
c = ['#define NDIRECT %d' % len(names), '#define NPROC %d' % NPROC,
     'static const char* const kDirect[NDIRECT + 1] = {%s};' % "".join('"%s",' % n for n in names) + "",
     ]
c += ['void rni_tramp_%d(void);' % i for i in range(NPROC)]
c.append('static void (*const kTramps[NPROC])(void) = {%s};' % ",".join("rni_tramp_%d" % i for i in range(NPROC)))
open(out + "/tables.h", "w").write("\n".join(c) + "\n")
PY
  [ -s "$out/tramps.S" ] || return 1
  cat > "$out/shim.c" <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tables.h"

__thread unsigned long rni_gl_tls_calls __attribute__((tls_model("initial-exec")));
__attribute__((visibility("hidden"))) void* rni_direct_real[NDIRECT + 1];
__attribute__((visibility("hidden"))) void* rni_proc_real[NPROC];
static const char* procNames[NPROC];
static int procUsed, overflow;
static pthread_mutex_t procMutex = PTHREAD_MUTEX_INITIALIZER;

unsigned long rni_gl_shim_thread_calls(void) { return rni_gl_tls_calls; }

static void* realDlsym(void* h, const char* n) {
  static void* (*fn)(void*, const char*);
  if (!fn) fn = (void* (*)(void*, const char*))dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.34");
  if (!fn) fn = (void* (*)(void*, const char*))dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.2.5");
  return fn(h, n);
}

static int isGl(const char* n) { return n && n[0] == 'g' && n[1] == 'l' && n[2] >= 'A' && n[2] <= 'Z'; }

static void* wrap(const char* name, void* real) {
  if (!real || !isGl(name)) return real;
  pthread_mutex_lock(&procMutex);
  void* out = real;
  int i;
  for (i = 0; i < procUsed; ++i)
    if (rni_proc_real[i] == real && strcmp(procNames[i], name) == 0) break;
  if (i < procUsed) {
    out = (void*)kTramps[i];
  } else if (procUsed < NPROC) {
    rni_proc_real[procUsed] = real;
    procNames[procUsed] = strdup(name);
    out = (void*)kTramps[procUsed++];
  } else {
    overflow = 1;  /* uncounted: reported at exit and failed by the gate */
  }
  pthread_mutex_unlock(&procMutex);
  return out;
}

typedef void* (*GetProc)(const char*);
static GetProc realEglGetProc;
void* eglGetProcAddress(const char* name) {
  if (!realEglGetProc) realEglGetProc = (GetProc)realDlsym(RTLD_NEXT, "eglGetProcAddress");
  return wrap(name, realEglGetProc ? realEglGetProc(name) : NULL);
}

void* dlsym(void* handle, const char* name) {
  void* r = realDlsym(handle, name);
  if (r && name && strcmp(name, "eglGetProcAddress") == 0) {
    if (!realEglGetProc) realEglGetProc = (GetProc)r;
    return (void*)&eglGetProcAddress;
  }
  return wrap(name, r);
}

__attribute__((constructor)) static void init(void) {
  for (int i = 0; i < NDIRECT; ++i) {
    /* null in a process without libGLESv2 (timeout, env): never called there */
    rni_direct_real[i] = realDlsym(RTLD_NEXT, kDirect[i]);
  }
}

__attribute__((destructor)) static void fini(void) {
  if (!rni_direct_real[0] && NDIRECT > 0) return;  /* not a GL process */
  fprintf(stderr, "gl_shim direct=%d proc_slots=%d overflow=%d\n", NDIRECT, procUsed, overflow);
}
C
  ${CC:-cc} -O1 -shared -fPIC -o "$out/libglcount.so" "$out/shim.c" "$out/tramps.S" -I"$out" -ldl -lpthread
}
