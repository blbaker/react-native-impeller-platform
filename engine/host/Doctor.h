// `rn-impeller --doctor` (linux matrix M2): what this engine would pick on
// THIS machine, and why, as key=value lines on stdout (one fact per line,
// greppable). Exit 0 whenever the report printed; a missing library or a dead
// rung is a reported fact, not a doctor failure.
//
// Sections (each key prefix is stable; tools/ci-doctor.sh greps them):
//   doctor.*     arch, exe
//   env.*        the variables that steer selection
//   window.*     GLFW backend chosen (host/GlfwPlatformSelect.h) and why, what
//                glfwInit actually got, a hidden-window EGL/GL probe, and the
//                libraries GLFW's own backend loads
//   egl.*, gl.*  the headless EGL ladder (host/HeadlessEglRungs.h): every rung's
//                result and why, the one that ran, vendor/version/extensions
//   gpu.*        software vs hardware; software = UNVERIFIED-ON-HARDWARE
//   dlopen.*     every optional library (host/OptionalLibs.h): list tried,
//                which soname resolved; ffmpeg per release set
//   video.*      the ffmpeg copy that plays (copies built: 8 then 6), and whether it loads
//   dma_heap     system:<ok|enoent|eacces|error> cma:<present|absent>: can this
//                user open /dev/dma_heap/system (web view frame slots; open +
//                close only), plus dma_heap.hint when it cannot (the udev rule
//                on eacces). Dir: RNI_DOCTOR_DMA_HEAP_DIR, default /dev/dma_heap
//   webhelper.*  where the web view helper is found and whether it starts
//                (`rni-webhelper --version`; host/DoctorImage.cpp)
//   image.*      the image contract (docs/IMAGE-REQUIREMENTS.md): own DT_NEEDED,
//                required dlopen libraries (image.missing, image.status), optional ones
#pragma once

#include <functional>
#include <string>

namespace rni::doctor {

using Emit = std::function<void(const std::string& key, const std::string& value)>;

bool Requested(int argc, char** argv);
int Main(int argc, char** argv);

// The window section (host/DoctorWindow.cpp). Builds without a window emit
// window.glfw_init=not_built.
void ReportWindow(const Emit& emit);

#if defined(__linux__) && !defined(__ANDROID__)
// host/DoctorImage.cpp. ReportWebHelper returns the image.optional.webview value.
std::string ReportWebHelper(const Emit& emit);
void ReportImage(const Emit& emit, const std::string& webview);
#endif

// "software" for llvmpipe/softpipe/swrast/SwiftShader GL_RENDERER strings.
const char* RendererClass(const char* glRenderer);

}  // namespace rni::doctor
