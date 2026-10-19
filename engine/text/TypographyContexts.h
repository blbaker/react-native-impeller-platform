#pragma once
// FP-12: one ImpellerTypographyContext per thread.
//
// impeller.h: "typography contexts are not thread-safe. These must be created,
// used, and collected on a single thread." Measure runs on the JS thread
// (ImpellerTextLayoutManager) and paint on the main thread (SceneGraph), so each
// thread gets its own context. The fonts live in one process-wide list; every
// context registers every font in list order before it is handed out, so measure
// and paint resolve the same family (app fonts and fallback faces) to the same
// face. Flutter keeps layout and its FontCollection on the UI thread
// (engine/src/flutter/lib/ui/text/font_collection.cc:155, UI-thread only); we keep
// that one-thread rule per context, with two layout threads.
#include <impeller.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace rni::typography {

// The calling thread's context, with every font in the list registered. A thread
// with no bound context gets its own on first use, released when the thread exits.
ImpellerTypographyContext ForThisThread();

// Makes `ctx` the calling thread's context. The caller created it on this thread,
// owns it, and calls Unbind before releasing it (the surfaces do this).
void Bind(ImpellerTypographyContext ctx);
void Unbind(ImpellerTypographyContext ctx);

// FP-32: after a GPU context loss every thread's OWN context is rebuilt on its
// next ForThisThread() call (on that thread: contexts are single-thread). The
// bound (paint) context is replaced by its surface with Unbind + Bind.
void Invalidate();

// Appends a font every context registers; returns its index. Any thread.
size_t AddFont(const std::string& path, std::shared_ptr<const std::vector<uint8_t>> bytes);

// Changes whenever text could shape differently than it did before: a font was
// added (AddFont) or the contexts were rebuilt (Invalidate). ParagraphCache
// keys on it.
uint64_t FontEpoch();

// Whether this thread's context accepted font `index` (syncs first).
bool RegisteredHere(size_t index);

// Prints `typography_contexts bound=B own=O fonts=F`: contexts bound by surfaces,
// contexts made by other threads on first use, fonts in the list (all-time counts).
void PrintSummary();

}  // namespace rni::typography
