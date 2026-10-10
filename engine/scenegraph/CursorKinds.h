#pragma once
// Cursor kinds shared by the scene graph (mapping from react::Cursor), the
// host (GLFW shape per kind) and the hover log (name per kind).
// Kinds 0..4 predate this file; 3 and 4 are darwin NSCursor extras.
#include <react/renderer/components/view/primitives.h>

namespace rni {

enum CursorKind : int {
  kCursorArrow = 0,
  kCursorHand = 1,
  kCursorIBeam = 2,
  kCursorGrab = 3,
  kCursorGrabbing = 4,
  kCursorCrosshair = 5,
  kCursorResizeEW = 6,
  kCursorResizeNS = 7,
  kCursorResizeNWSE = 8,
  kCursorResizeNESW = 9,
  kCursorResizeAll = 10,
  kCursorNotAllowed = 11,
  kCursorKindCount = 12,
};

inline const char* CursorKindName(int kind) {
  switch (kind) {
    case kCursorHand: return "hand";
    case kCursorIBeam: return "ibeam";
    case kCursorGrab: return "grab";
    case kCursorGrabbing: return "grabbing";
    case kCursorCrosshair: return "crosshair";
    case kCursorResizeEW: return "resize-ew";
    case kCursorResizeNS: return "resize-ns";
    case kCursorResizeNWSE: return "resize-nwse";
    case kCursorResizeNESW: return "resize-nesw";
    case kCursorResizeAll: return "resize-all";
    case kCursorNotAllowed: return "not-allowed";
    default: return "arrow";
  }
}

// Closest GLFW 3.4 standard cursor for each RN value. Auto/Default stay arrow
// (and mean "inherit" in cursorKindFor). Values GLFW has no shape for
// (Wait, Progress, Help, ZoomIn, ...) also read as arrow.
inline int CursorKindFromRN(facebook::react::Cursor cursor) {
  using facebook::react::Cursor;
  switch (cursor) {
    case Cursor::Pointer:
    case Cursor::Url:
    case Cursor::Alias:
      return kCursorHand;
    case Cursor::Text: return kCursorIBeam;
    case Cursor::Grab: return kCursorGrab;
    case Cursor::Grabbing: return kCursorGrabbing;
    case Cursor::Crosshair:
    case Cursor::Cell:
      return kCursorCrosshair;
    case Cursor::ColResize:
    case Cursor::EResize:
    case Cursor::WResize:
    case Cursor::EWResize:
      return kCursorResizeEW;
    case Cursor::RowResize:
    case Cursor::NResize:
    case Cursor::SResize:
    case Cursor::NSResize:
      return kCursorResizeNS;
    case Cursor::NWResize:
    case Cursor::SEResize:
    case Cursor::NWSEResize:
      return kCursorResizeNWSE;
    case Cursor::NEResize:
    case Cursor::SWResize:
    case Cursor::NESWResize:
      return kCursorResizeNESW;
    case Cursor::AllScroll:
    case Cursor::Move:
      return kCursorResizeAll;
    case Cursor::NotAllowed:
    case Cursor::NoDrop:
      return kCursorNotAllowed;
    default: return kCursorArrow;
  }
}

}  // namespace rni
