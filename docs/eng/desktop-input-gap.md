# Desktop input + window gap audit (react-native-impeller)

Branch `feat/desktop-input` off `origin/main` 6d2dea2. Written 2026-09-30.

## Why this exists

The macOS tester's "DESKTOP INPUT BASELINE" request (internal request) listed what Baker hit on macOS. That list is one OS and
one user's afternoon. This audit lists what a desktop RN app is expected to do on
**macOS, Windows and Linux**, using two reference implementations:

- `microsoft/react-native-macos` @ ff07685 (`packages/react-native`)
- `microsoft/react-native-windows` @ dac75b6 (`vnext/`)

Sparse clones live in `~/projects/_ref/` (not committed). Every "Impeller today"
entry below is a grep or read of this tree, not a guess.

Legend: **Host** = our `GlfwSurface` / `FabricHost` / `ReactHost`.
**GLFW** = can be built and gated on WSL. **Cocoa** = darwin patch the Mac builds.
**Win32** = needs the Windows windowed build (see section J).

## A. Keyboard

| Item | Ref | Impeller today | Where |
|---|---|---|---|
| Every key down/repeat/up with modifiers to JS | rn-macos `RCTViewComponentView keyDown/keyUp` -> `onKeyDown/onKeyUp` with shift/ctrl/alt/meta/capsLock/function; rn-windows `onKeyDown/onKeyUp` + `Capture` variants with `code` | Key callback forwards Backspace and Enter only; release dropped | GLFW |
| `onKeyDown`/`onKeyUp` on **any focusable View**, not only TextInput | RN 0.86 `ViewPropTypes` already declares them; both forks emit them | 0 hits for `onKeyDown`/`topKeyDown` in host/fabric | Host |
| `keyDownEvents` / `keyUpEvents` (JS marks a key handled, native default is skipped) | rn-macos + rn-windows `HandledKeyEvent` | none | Host |
| TextInput `onKeyPress` | RN core | none (0 hits) | Host |
| Physical `code` (`KeyA`) vs layout `key` (`a`) | rn-windows `KeyEvent.code` | no scancode forwarded | GLFW |
| Keyboard scroll: arrows, PageUp/Down, Home/End scroll the focused ScrollView | rn-windows `ScrollViewComponentView` handles Up/Down/Left/Right/PageUp/PageDown/Home/End | wheel only | Host |
| Ctrl vs Cmd: shortcuts use Cmd on macOS, Ctrl on Windows/Linux | platform convention | n/a yet | Host |

Note: RN 0.86's C++ `BaseViewEventEmitter` has no `onKeyDown`/`onKeyUp`
(only focus, blur, layout, a11y), even though the JS `ViewPropTypes` declares
them. View key events need a generic `dispatchEvent("keyDown", ...)` plus the
`topKeyDown`/`topKeyUp` bubbling registration in the view config, as both forks
do. `TextInputEventEmitter::onKeyPress` already exists in core.

## B. TextInput editing

| Item | Ref | Impeller today | Where |
|---|---|---|---|
| Caret movement: char, word (Alt/Ctrl+arrow), line (Cmd+arrow / Home/End) | rn-macos NSTextView; rn-windows RichEdit (`ITextServices`) | caret pinned to end of buffer (`FabricHost.cpp:769`) | Host |
| Click puts caret at glyph | both | not implemented | Host |
| Forward Delete | both | not implemented | Host |
| **Non-ASCII typing** (é, ü, curly quotes, emoji) | both (UTF-16 native) | `InsertChar` accepts 0x20-0x7E only (`FabricHost.cpp:776`); every other codepoint is dropped | Host |
| **IME / dead keys / compose** (Option+e then e, CJK input) | rn-macos NSTextInputClient; rn-windows RichEdit | none. GLFW has no preedit API in 3.4 | Cocoa + Win32 |
| **multiline** TextInput (Enter inserts newline, Up/Down between lines, wraps) | RN core | single-line only; Shift+Enter "is a later arm" (`FabricHost.cpp:792`) | Host |
| Undo / redo | both | none | Host |
| `onSelectionChange`, `selection` prop, `setSelection` | RN core | none (ENG-11) | Host |
| Selection highlight + `selectionColor` | RN core | none | Host |
| `onPaste` / `pastedTypes` | rn-macos | none | Host |
| `submitKeyEvents` / `clearTextOnSubmit` | rn-macos + rn-windows | none | Host |
| Default right-click menu: Cut/Copy/Paste/Select All, greyed when not applicable | rn-windows `WindowsTextInputComponentView::ShowContextMenu` (`AppendMenuW`) ; macOS gets it from NSTextView | none | Cocoa + Win32, or drawn by host |

## C. Selectable Text

| Item | Ref | Impeller today | Where |
|---|---|---|---|
| `<Text selectable>`: drag select, double-click word, highlight | rn-windows `ParagraphComponentView` (own selection + `DrawSelectionHighlight`); rn-macos swaps in an `NSTextView` | not honoured | Host |
| Copy from selectable Text (Cmd/Ctrl+C + context menu Copy/Select All) | rn-windows `CopySelectionToClipboard`, `ShowContextMenu` | none | Host |
| One selection per window (starting a new one clears the old) | rn-windows `ClearCurrentTextSelection` on the root | none | Host |

## D. Mouse and pointer

| Item | Ref | Impeller today | Where |
|---|---|---|---|
| Right and middle button | rn-macos `rightMouseDown/Up`, `otherMouseDown/Up` -> `onAuxClick` button 2 / 1; rn-windows `WM_RBUTTON*`, `WM_MBUTTON*`, `WM_XBUTTON*` (back/forward) | `if (button != GLFW_MOUSE_BUTTON_LEFT) return;` (`GlfwSurface.cpp:388`) | GLFW |
| Click count | rn-macos `event.clickCount` -> `onDoubleClick`; rn-windows `IsDoubleClick` | none | GLFW (count in host) |
| `onClick` / `onAuxClick` / `onDoubleClick` on View | RN 0.86 declares `onClick`; forks add the other two | 0 hits | Host |
| `onPointerDown/Up/Move` with `button`, `buttons`, modifier keys | RN core PointerEvent | only Enter/Leave emitted | Host |
| Modifier keys on clicks (Shift+click range select, Cmd/Ctrl+click) | both | mods ignored in button callback | GLFW |
| Horizontal wheel + Shift+wheel | both | scroll callback exists; x offset path not verified | GLFW |
| Cursor shapes beyond arrow/hand/ibeam (`not-allowed`, resize family, crosshair) | rn-macos `cursor` has the CSS set | 3 shapes | GLFW 3.4 has them |
| `tooltip` prop | rn-macos `self.toolTip`; rn-windows `TooltipService` | 0 hits | Host-drawn, or Cocoa/Win32 |
| Drag and drop files in (`onDragEnter/Leave/Drop`, `draggedTypes`) | rn-macos | no `glfwSetDropCallback` | GLFW (drop only) |

## E. Clipboard

| Item | Ref | Impeller today | Where |
|---|---|---|---|
| `Clipboard.getString/setString` module | rn-macos `RCTClipboard` (NSPasteboard); rn-windows `ClipboardModule` (DataTransfer) | not registered; RN's `NativeClipboard.js` finds nothing | GLFW |
| Cut/Copy/Paste keys in TextInput | both | none | Host |

## F. Focus and keyboard navigation

| Item | Ref | Impeller today | Where |
|---|---|---|---|
| **Tab / Shift+Tab** moves focus between focusable views | rn-windows `CompositionEventHandler` Tab + `FocusManager::NavigateFocus`; rn-macos key view loop | none | Host |
| `focusable`, `tabIndex`, `onFocus/onBlur` on View | rn-windows `tabIndex`; rn-macos `focusable` | TextInput only | Host |
| Focus ring (`enableFocusRing`) | both | none | Host |
| Escape blurs / closes modal | platform convention | none | Host |

## G. Window and app lifecycle

| Item | Ref | Impeller today | Where |
|---|---|---|---|
| Title | both | hard-coded string (`GlfwSurface.cpp:284`) | GLFW (`glfwSetWindowTitle`) |
| Window focus/blur -> `AppState` active/inactive | rn-macos `RCTAppState` (`isActive`/`isHidden`) | AppState module registered, no events (no `glfwSetWindowFocusCallback`) | GLFW |
| Minimise -> AppState background | rn-macos `isHidden` | no iconify callback | GLFW |
| Monitor DPI change (drag to a 1x screen) -> `Dimensions` | rn-windows `WM_DPICHANGED` in DeviceInfo | no content-scale callback | GLFW |
| Close button: let JS block or confirm (unsaved work) | platform convention | no `glfwSetWindowCloseCallback` | GLFW |
| Min window size | platform convention | none | GLFW (`glfwSetWindowSizeLimits`) |
| Save/restore size and position | platform convention | none | Host |
| Light/dark change while running -> `Appearance` listeners | both | ENG-17: subscribers never re-render | Host |
| Reduce motion / a11y settings | both | ENG-14: AccessibilityManager not registered | Host |

## H. Menus and system chrome

| Item | Ref | Impeller today | Where |
|---|---|---|---|
| macOS Edit menu (Undo/Redo/Cut/Copy/Paste/Select All) routed to focused field | macOS convention | GLFW builds App + Window menus only (`cocoa_init.m`), no Edit menu | Cocoa |
| App-defined menu items | rn-macos via native module | none | Cocoa + Win32 |
| Windows: Alt+Space system menu, Alt+F4 | Win32 default | GLFW gives these free once windowed on Windows | Win32 |

## I. Accessibility

| Item | Ref | Impeller today | Where |
|---|---|---|---|
| Screen reader tree | rn-macos NSAccessibility; rn-windows full UIA providers (`CompositionDynamicAutomationProvider`, text range providers) | none | Cocoa + Win32 |

## J. Platform coverage

- **Windows has no window.** `RNI_WITH_WINDOW` defaults OFF on WIN32
  (`engine/CMakeLists.txt:30`). `WinGLSurface` is headless. Every item marked
  GLFW works on Windows only after that build exists.
- **Linux is X11 only.** `glfw-fetch.sh` builds with `GLFW_BUILD_WAYLAND=OFF`.
  Clipboard and IME behave differently under Wayland.

## Proposed order

P0 (blocks basic use on every OS):

1. A: full key events + modifiers, `onKeyDown/onKeyUp` on View, TextInput `onKeyPress` -- **LANDED** on feat/desktop-input (gate `tools/ci-key-events.sh`, mutants `tools/mutation-verify-key-events.sh` M1-M4)
2. B: caret, click-to-caret, forward Delete, **UTF-8 input** (drop the ASCII filter) -- caret keys + forward Delete + UTF-8 **LANDED** (gate `tools/ci-caret-edit.sh`, mutants `tools/mutation-verify-caret-edit.sh` M1-M4); click-to-caret still pending
3. B/C: selection in TextInput (ENG-11) + highlight
4. E: Clipboard module + Cut/Copy/Paste keys, Cmd on macOS, Ctrl elsewhere
5. D: right/middle/back/forward buttons, click count, modifiers on clicks
6. F: Tab / Shift+Tab focus traversal

P1:

7. B: multiline TextInput, undo/redo, default TextInput context menu
8. C: `<Text selectable>` + copy
9. G: title, focus/blur/minimise -> AppState, close callback, min size, DPI change
10. H: macOS Edit menu (Cocoa patch for the Mac)
11. A: keyboard scrolling in ScrollView
12. D: `tooltip`, full cursor set, file drop
13. Ledger: ENG-13 dash, ENG-14 a11y manager, ENG-15 Switch, ENG-17 appearance

P2:

14. B: IME / compose (needs Cocoa + Win32 work; GLFW has no preedit)
15. I: screen reader tree
16. J: Windows windowed build, Wayland

Each landed item gets a windowed gate plus a mutant that must fail, per the
macOS tester's request.
