// FP-32: main thread's side of a GPU context loss (host/ContextLoss.h).
// Model: shell.cc OnPlatformViewDestroyed + OnPlatformViewCreated run back to
// back: Rasterizer::Teardown/Setup on the raster thread (WindowRasterizer::
// RebuildGpu), the IO manager's resource context recreated with it, then the
// UI side told to draw a new frame (Engine::ScheduleFrame). RN has no shell
// "platform view" to recreate, so main also drops RECORD's GPU caches and the
// paint thread's typography context, which only it may touch.
#pragma once

namespace rni {

class GlfwSurface;
class SceneGraph;
class WindowRasterizer;

// True when everything is rebuilt; false leaves the loss pending (retried on
// the next frame).
bool RecoverContext(WindowRasterizer& rasterizer, GlfwSurface& surface, SceneGraph& scene);

}  // namespace rni
