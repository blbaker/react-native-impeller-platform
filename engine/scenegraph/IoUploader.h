// FP-17: image texture upload on the IO thread, off the raster thread.
//
// Model: Flutter's IO runner (docs/about/The-Engine-architecture.md "IO task
// runner": one thread owning a context in the raster context's share group)
// and ImageDecoderImpeller (lib/ui/painting/image_decoder_impeller.cc): the
// decode runs on the concurrent pool, the GLES upload is posted to the IO
// runner ("The I/O image uploads are not threadsafe on GLES"), and the image
// result is delivered only after the upload is complete. The interop API has no
// tracking fence (Context::AddTrackingFence), so we take Flutter's other branch,
// command_buffer->WaitUntilCompleted(): the IO thread waits on a GL fence before
// the hand-off, and the raster thread only wraps a finished texture name.
//
// rni::image (FP-16) calls the upload hook after a successful pool decode; the
// load completes (cache insert, onLoad, repaint) only after the hand-off. The
// painter takes the finished name once per decoded image (Take) and wraps it
// with ImpellerTextureCreateWithOpenGLTextureHandleNew, which makes no GL call;
// the wrapper then owns the name (Impeller's reactor deletes it on collection).
#pragma once

#include <cstdint>
#include <functional>

namespace rni::image {
struct Decoded;
}

namespace rni::io {

// The host's share-group context, bound/unbound on the IO thread.
struct ContextHooks {
  std::function<bool()> bind;
  std::function<void()> unbind;
};

// Global switch (--io-upload on|off, default on). Off: no IO thread; images
// upload on the raster side as before (FP-14 jobs).
void SetEnabled(bool on);
bool Enabled();

// Starts the IO thread and installs the rni::image upload hook. False (and the
// raster path stays in use) when disabled or when bind fails on the thread.
bool Start(ContextHooks hooks);
// Uninstalls the hook, completes queued loads without uploading, deletes names
// nobody took, unbinds, joins. Call before the share group's contexts die.
void Stop();

// RECORD side, no GL: the finished GL name for `d`, handed over once. 0 when
// the IO thread did not upload it (disabled, failed, or not yet).
uint32_t Take(const image::Decoded* d);

// `io_upload enabled= running= uploads= taken= failed= max_us= delay_ms=`
void PrintStats();

}  // namespace rni::io
