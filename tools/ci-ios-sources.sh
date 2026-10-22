#!/usr/bin/env bash
# iOS ENGINE SOURCE LIST GATE (linux, no Mac): every platform-neutral engine
# file the desktop rn-impeller binary compiles is also in the iOS engine
# (engine/ios/RniIosEngine.cmake or RniIos.cmake), unless one of the rules
# that header documents excludes it. And every engine file the iOS lists
# name exists.
#
# Why: the iOS list is written by hand. PR #40 added
# scenegraph/SceneGraphTextSelection.cpp to the desktop list only; desktop CI
# stayed green, and every iOS app link failed with undefined
# rni::SceneGraph::selectedText() etc. No CI job builds iOS (it needs a Mac),
# so this static check is the CI guard; tools/ci-ios-device-build.sh is the
# build proof.
#
# Exclusions (the RniIosEngine.cmake header's rules, as code):
#   host/*                 the desktop host (GLFW, X11, ANGLE/EGL, Win32); iOS's
#                          host is engine/ios/
#   *Gl.cpp *GlWin.cpp base/Gl*.cpp base/ProgramCount.cpp   GL; iOS is Metal only
#   modules/*{Darwin,Linux,Win}.{cpp,mm}, modules/NotificationsAppName.cpp
#                          desktop OS backends; iOS has its own (*IOS.mm,
#                          NotificationsNull.cpp)
#   modules/AccessibilitySettings.cpp   the iOS reader is AccessibilitySettingsIOS.mm
#   svg/*                  built by cmake/RnSvg.cmake, shared by both
# Overrides for tests: RNI_DESKTOP_CMAKE, RNI_IOS_CMAKES (space separated).
# Pass line: IOS_SOURCES_PASS (<n> shared files). Mutants:
# tools/mutation-verify-ios-sources.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESK="${RNI_DESKTOP_CMAKE:-$ROOT/engine/CMakeLists.txt}"
IOS="${RNI_IOS_CMAKES:-$ROOT/engine/ios/RniIosEngine.cmake $ROOT/engine/ios/RniIos.cmake}"
python3 - "$ROOT/engine" "$DESK" $IOS << 'PY'
import os, re, sys
eng, desk, ios = sys.argv[1], sys.argv[2], sys.argv[3:]
DIRS = "scenegraph|fabric|text|runtime|modules|base|host|svg|world"
pat = re.compile(r"(?:\$\{CMAKE_SOURCE_DIR\}/|\$\{_E\}/|(?<![\w/.$}]))((?:%s)/[A-Za-z0-9_/]+\.(?:cpp|mm|cc))" % DIRS)
def files(paths):
    out = set()
    for p in paths:
        for line in open(p):
            out.update(pat.findall(line.split("#", 1)[0]))
    return out
def excluded(f):
    base = os.path.basename(f)
    if f.startswith(("host/", "svg/")): return "desktop host / RnSvg.cmake"
    if re.search(r"Gl(Win)?\.cpp$", base) or f.startswith("base/Gl") or f == "base/ProgramCount.cpp": return "GL"
    if f.startswith("modules/") and re.search(r"(Darwin|Linux|Win)\.(cpp|mm)$", base): return "desktop OS backend"
    if f in ("modules/NotificationsAppName.cpp", "modules/AccessibilitySettings.cpp"): return "iOS has its own"
    return None
d, i = files([desk]), files(ios)
if len(d) < 50 or len(i) < 40:
    print(f"IOS_SOURCES_FAIL: parsed {len(d)} desktop / {len(i)} iOS files; the lists moved, fix the parser")
    sys.exit(1)
fails = []
for f in sorted(d - i):
    if not excluded(f):
        fails.append(f"IOS_SOURCES FAIL missing: {f} is in the desktop build but not the iOS engine "
                     f"(add it to engine/ios/RniIosEngine.cmake, or add an exclusion rule here with its reason)")
for f in sorted(i):
    if not os.path.exists(os.path.join(eng, f)):
        fails.append(f"IOS_SOURCES FAIL stale: engine/ios lists {f}, which does not exist")
shared = len(d & i)
print(f"desktop {len(d)} files, iOS {len(i)}, shared {shared}, desktop-only excluded {len([f for f in d - i if excluded(f)])}")
for f in fails: print(f)
if fails:
    print(f"IOS_SOURCES_FAIL ({len(fails)})"); sys.exit(1)
print(f"IOS_SOURCES_PASS ({shared} shared files)")
PY
