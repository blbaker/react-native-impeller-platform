// FP-17: the IO thread's GL context, in the raster context's EGL share group
// (Flutter: the IO runner's resource context, "in the same sharegroup as the
// main raster task runner context", docs/about/The-Engine-architecture.md).
#pragma once

namespace rni::ioegl {

// Call on the thread whose EGL context Impeller draws with, while it is current.
// Creates a context sharing with it (surfaceless, else a 1x1 pbuffer) and starts
// rni::io's upload thread on it. False (raster-side uploads stay) when EGL is
// unavailable (Windows GLFW/WGL hosts), --io-upload off, or any step fails.
// Prints `io_context ok= share= reason=`.
bool StartFromCurrent();

// rni::io::Stop(), then destroys the context. Call before the raster context dies.
void Stop();

}  // namespace rni::ioegl
