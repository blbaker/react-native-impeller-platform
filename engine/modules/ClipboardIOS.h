// iOS Phase 1 / Task 1.5: UIPasteboard as the system backend of the existing
// ClipboardBridge (modules/ClipboardBridge.h), the iOS counterpart of the GLFW
// clipboard pair main.cpp installs on desktop.
//
// UIPasteboard is UIKit: main thread. The bridge already funnels every system
// access through its FIFO + drainMain(); on iOS there is no frame loop calling
// drainMain(), so the wake this installs schedules drainMain() on the main
// dispatch queue itself. FIFO order (a write posted before a read resolves
// first) is the bridge's, unchanged.
// ⛔ iOS 16+ shows a "paste from <app>" consent alert when an app reads
// pasteboard content another app wrote. Reads go through UIPasteboard.string
// like RN's own Clipboard module; the alert is iOS behaviour, not a bug here.
#pragma once

namespace rni {

class ClipboardBridge;

// Any thread. `bridge` must outlive the app (the wake captures it).
void InstallIOSClipboard(ClipboardBridge& bridge);

}  // namespace rni
