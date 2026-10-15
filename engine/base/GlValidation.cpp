#include "base/GlValidation.h"

#include <GLES3/gl32.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace rni::glvalidation {
namespace {

enum class Mode { kUnset, kOff, kCount, kAbort };

Mode ReadMode() {
  const char* v = std::getenv("RNI_GL_VALIDATION");
  if (!v || !*v || !std::strcmp(v, "0")) return Mode::kOff;
  return std::strcmp(v, "abort") == 0 ? Mode::kAbort : Mode::kCount;
}

Mode GetMode() {
  static const Mode mode = ReadMode();
  return mode;
}

std::atomic<uint64_t> gErrors{0};
std::atomic<uint64_t> gMessages{0};
std::atomic<int> gContexts{0};
std::atomic<int> gFrame{0};
std::atomic<int> gPrinted{0};

using DebugCallback = void(GL_APIENTRY*)(GLenum, GLenum, GLuint, GLenum, GLsizei, const GLchar*,
                                         const void*);
using DebugMessageCallbackFn = void(GL_APIENTRY*)(DebugCallback, const void*);
using EnableFn = void(GL_APIENTRY*)(GLenum);
using BindTextureFn = void(GL_APIENTRY*)(GLenum, GLuint);

BindTextureFn gBindTexture = nullptr;
using GetErrorFn = GLenum(GL_APIENTRY*)();
GetErrorFn gGetError = nullptr;

const char* TypeName(GLenum t) {
  switch (t) {
    case GL_DEBUG_TYPE_ERROR: return "error";
    case GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR: return "deprecated";
    case GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR: return "undefined";
    case GL_DEBUG_TYPE_PORTABILITY: return "portability";
    case GL_DEBUG_TYPE_PERFORMANCE: return "performance";
    default: return "other";
  }
}

void GL_APIENTRY OnMessage(GLenum source, GLenum type, GLuint id, GLenum severity, GLsizei length,
                           const GLchar* message, const void*) {
  gMessages.fetch_add(1, std::memory_order_relaxed);
  const bool isError = type == GL_DEBUG_TYPE_ERROR || severity == GL_DEBUG_SEVERITY_HIGH;
  if (isError) gErrors.fetch_add(1, std::memory_order_relaxed);
  // Notifications are driver chatter; print only what is a problem, capped.
  if (severity == GL_DEBUG_SEVERITY_NOTIFICATION && !isError) return;
  if (gPrinted.fetch_add(1, std::memory_order_relaxed) < 40) {
    std::fprintf(stderr, "rn-impeller: gl_validation: %s type=%s id=0x%x severity=0x%x source=0x%x %.*s\n",
                 isError ? "ERROR" : "message", TypeName(type), id, severity, source,
                 (int)(length > 0 ? length : (GLsizei)std::strlen(message)), message);
    std::fflush(stderr);
  }
  if (isError && GetMode() == Mode::kAbort) std::abort();
}

}  // namespace

bool Enabled() { return GetMode() == Mode::kCount || GetMode() == Mode::kAbort; }

bool Install(ProcLoader loader, void* userData) {
  if (!Enabled()) return false;
  auto cb = reinterpret_cast<DebugMessageCallbackFn>(loader("glDebugMessageCallback", userData));
  if (!cb) cb = reinterpret_cast<DebugMessageCallbackFn>(loader("glDebugMessageCallbackKHR", userData));
  auto enable = reinterpret_cast<EnableFn>(loader("glEnable", userData));
  if (!cb || !enable) {
    std::fprintf(stderr, "rn-impeller: gl_validation: KHR_debug entry points missing\n");
    return false;
  }
  gBindTexture = reinterpret_cast<BindTextureFn>(loader("glBindTexture", userData));
  gGetError = reinterpret_cast<GetErrorFn>(loader("glGetError", userData));
  // Synchronous so the message lands on the thread and call that caused it (and abort mode
  // stops in the offending frame).
  enable(GL_DEBUG_OUTPUT);
  enable(GL_DEBUG_OUTPUT_SYNCHRONOUS);
  cb(&OnMessage, nullptr);
  std::printf("rn-impeller: gl_validation=on mode=%s context=%d\n",
              GetMode() == Mode::kAbort ? "abort" : "count", gContexts.fetch_add(1) + 1);
  std::fflush(stdout);
  return true;
}

void OnFrame() {
  if (!Enabled()) return;
  const int frame = gFrame.fetch_add(1) + 1;
  const char* hook = std::getenv("RNI_TEST_GL_BAD_BIND");
  if (frame == 2 && hook && !std::strcmp(hook, "1") && gBindTexture) {
    gBindTexture(GL_TEXTURE_2D, 0xDEAD);  // never generated: an error on ANGLE, tolerated by Mesa
    gBindTexture(0xDEAD, 0);              // invalid target: GL_INVALID_ENUM everywhere
    // Drain the sticky error so the hook is seen by KHR_debug only, not by glReadPixels checks.
    if (gGetError) while (gGetError() != GL_NO_ERROR) {}
  }
}

uint64_t ErrorCount() { return gErrors.load(); }

void Finish() {
  if (!Enabled()) {
    std::printf("rn-impeller: gl_validation=off\n");
    return;
  }
  std::printf("rn-impeller: gl_validation_errors=%llu gl_validation_messages=%llu contexts=%d\n",
              (unsigned long long)gErrors.load(), (unsigned long long)gMessages.load(),
              gContexts.load());
}

}  // namespace rni::glvalidation
