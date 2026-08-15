#!/usr/bin/env bash
# Build the rn-impeller engine host and stage it into a per-platform npm package
# under packages-engine/engine-<platform>-<arch>/.
#
# The package is self-contained: engine binary + libimpeller.so + libhermesvm.so,
# with an rpath of $ORIGIN so the binary finds its libraries wherever npm unpacks
# it. A binary that only runs from the build tree is not a shippable package.
#
# ⚠️ THIS SCRIPT IS THE ONLY THING THAT PRODUCES THE GATED BINARY. It used to
# compile host/main.cpp with a standalone g++ line, and when the engine became a
# CMake project that line kept working — it just built a DIFFERENT, older
# program, so the consumer gate went green against an engine that no longer
# reflected the source tree. Anything that builds the engine must go through
# CMake here.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

# ⛔ THE TRIPLE IS node's `process.platform`-`process.arch`, NOT a friendly name.
# `resolve.js` computes the package name from those values at runtime, so the
# directory here must be `win32-x64` and never `windows-x64`: a mismatch produces
# a package that publishes fine, installs fine, and can never be found.
PLATFORM="${1:-linux}"
ARCH="${2:-x64}"
case "${PLATFORM}" in
  windows|win) PLATFORM=win32 ;;
esac
TRIPLE="${PLATFORM}-${ARCH}"
PKG="packages-engine/engine-${TRIPLE}"
VERSION="$(node -p "require('${ROOT}/package/package.json').version")"

case "${PLATFORM}" in
  linux)  ;;
  darwin) ;;
  win32) exec bash tools/engine-build-win-stage.sh "${ARCH}" ;;
  *) echo "engine-build: ${PLATFORM} is not supported yet" >&2; exit 1 ;;
esac

# ⛔ EVERY TOOL BELOW WAS THE LINUX ONE, AND THE MAC HAS NONE OF THEM.
# nproc, ldd, readelf and `strip --strip-unneeded` are GNU; macOS ships sysctl,
# otool and a BSD strip. The failure mode is what makes this worth a block
# comment: `ldd` is simply absent, so `MISSING="$(ldd ... || true)"` yields an
# EMPTY STRING and the "no unresolved libraries" assertion PASSES having tested
# nothing. A gate that cannot run must fail, not silently succeed — the same
# rule the Windows gate learned in P5-E.
case "$(uname -s)" in
  Darwin)
    NPROC_CMD="sysctl -n hw.ncpu"
    IMPELLER_LIB="libimpeller.dylib"
    STRIP_CMD="strip -x"
    ;;
  *)
    NPROC_CMD="nproc"
    IMPELLER_LIB="libimpeller.so"
    STRIP_CMD="strip --strip-unneeded"
    ;;
esac
JOBS="$(${NPROC_CMD})"

SDK="${IMPELLER_SDK:-}"
if [ -z "${SDK}" ]; then
  case "${PLATFORM}" in
    darwin) SDK="engine/third_party/impeller-sdk-darwin" ;;
    *)      SDK="engine/third_party/impeller-sdk" ;;
  esac
fi
if [ ! -f "${SDK}/include/impeller.h" ]; then
  case "${PLATFORM}" in
    darwin) bash tools/sdk-fetch-darwin.sh ;;
    *)      bash tools/sdk-fetch.sh "${SDK}" ;;
  esac
fi

# macOS reaches GLES3 through ANGLE for the same reason Windows does — the SDK's
# only offscreen surface constructor takes a GL framebuffer, and macOS ships
# neither GLES nor EGL. Staged here so a fresh Mac needs no manual step.
if [ "${PLATFORM}" = "darwin" ] && [ ! -f "engine/third_party/angle-darwin-arm64/libEGL.dylib" ]; then
  ANGLE_PLATFORM=darwin-arm64 bash tools/angle-fetch.sh
fi

# ⛔ ORDER IS LOAD-BEARING: THE RN PIN INSTALLS BEFORE HERMES BUILDS.
# hermes-build.sh reads the Hermes tag from
# engine/rn/node_modules/react-native/sdks/.hermesversion — deriving it from RN
# rather than hardcoding it is deliberate (an RN bump carries its own Hermes
# bump). So the install is a PREREQUISITE of the Hermes build, not a peer.
#
# These two lines were the other way round, which worked on every developer box
# and only on developer boxes: node_modules was already there from a previous
# run, so the dependency was satisfied by history rather than by the script. The
# first CI run on a clean clone failed here —
#
#     hermes-build: FAIL: .../engine/rn/node_modules/react-native not installed
#
# a cold-start defect that no amount of green local runs could surface. This is
# exactly the class of bug CI exists to find, found on its first run.
[ -d "engine/rn/node_modules/react-native" ] || (cd engine/rn && npm install --ignore-scripts --no-audit --no-fund)
# ⛔ THE GUARD MUST ASSERT WHAT CMAKE ACTUALLY NEEDS, NOT JUST THE LIBRARY.
# CMakeLists.txt requires BOTH the Hermes build output (libhermesvm.so) AND the
# Hermes SOURCE checkout (API/hermes/hermes.h, for headers). This line used to
# test only the .so, which is satisfiable WITHOUT the source — and a CI cache
# that restored `hermes-build` but not `hermes` did exactly that: the build was
# skipped as "already done" and CMake then failed with
#
#     Hermes not found at .../third_party/hermes. Run: bash tools/hermes-build.sh
#
# on a warm run, for a repo whose COLD run had just succeeded. A cache that
# makes the second run fail where the first passed is the worst kind, because
# it looks like a flaky build rather than a missing precondition.
#
# Testing both halves makes this self-healing regardless of what a cache
# restored: whatever is missing, hermes-build.sh runs and supplies it.
#
# ⛔ AND THE LIBRARY PATH IS PER-HOST — MEASURED, NOT GUESSED.
# I predicted macOS would emit libhermesvm.dylib. It does not: Hermes' CMake
# builds a macOS FRAMEWORK BUNDLE, so the artifact is
#   hermes-build/lib/hermesvm.framework/Versions/0/hermesvm
# with no .dylib anywhere. Either wrong answer (.so or .dylib) is never
# satisfied on a Mac, so hermes-build.sh would rerun on EVERY invocation —
# turning a one-time 40-minute compile into a permanent one, while still
# "working". Verified by listing the tree after the first real Mac build.
case "$(uname -s)" in
  Darwin) HERMES_VM="engine/third_party/hermes-build/lib/hermesvm.framework/Versions/0/hermesvm" ;;
  *)      HERMES_VM="engine/third_party/hermes-build/lib/libhermesvm.so" ;;
esac
[ -f "${HERMES_VM}" ] \
  && [ -f "engine/third_party/hermes/API/hermes/hermes.h" ] \
  || bash tools/hermes-build.sh

echo "engine-build: configuring + compiling ${TRIPLE} host (cmake)"
# ⛔ CMAKE 4 REMOVED COMPATIBILITY WITH cmake_minimum_required(<3.5), AND OUR
# OWN TREE IS NOT THE PROBLEM. engine/CMakeLists.txt already asks for 3.24;
# the offender is VENDORED — React Native's double-conversion (and folly's
# other FetchContent deps) still declare a floor below 3.5, so on cmake 4.x
# configure dies with:
#
#   Compatibility with CMake < 3.5 has been removed from CMake.
#
# This is HOST TOOLCHAIN SKEW, not a macOS defect: it reproduces on any box
# with cmake >= 4 and was invisible here only because this one has 3.28.
# Setting the policy floor for the sub-projects is the documented escape hatch
# and changes nothing about how OUR targets are configured. Applied
# unconditionally so a Linux contributor on cmake 4 gets the same result.
cmake -S engine -B engine/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_INSTALL_PREFIX="${ROOT}/${PKG}" > /dev/null
cmake --build engine/build -j"${JOBS}" --target rn-impeller

# `cmake --install` (not cp) — it rewrites the rpath from the build tree's
# absolute paths to $ORIGIN and stages libimpeller.so + libhermesvm.so with it.
# --component engine is REQUIRED: without it CMake also runs the install rules
# of every FetchContent'd dependency (glog, fmt, ...) and their headers end up
# inside the shipped package.
rm -rf "${PKG}/bin" "${PKG}/include" "${PKG}/lib" "${PKG}/share"
cmake --install engine/build --component engine > /dev/null
${STRIP_CMD} "${PKG}/bin/rn-impeller" 2>/dev/null || true

# The package must contain the payload and NOTHING ELSE. A dependency that
# quietly adds an install rule would otherwise ship its whole header tree to
# every consumer, and npm pack would not complain.
STRAY="$(cd "${PKG}" && ls -A | grep -vE '^(bin|package\.json|README\.md)$' || true)"
[ -z "$STRAY" ] || { echo "engine-build: FAIL — stray files staged into the package:"; echo "$STRAY"; exit 1; }
# ANGLE ships two extra dylibs on darwin, plus its LICENSE, and Hermes' macOS
# artifact is the FRAMEWORK BINARY named `hermesvm` — not libhermesvm.dylib.
# All payload, not strays. (Windows stages its own set via the win script.)
case "${PLATFORM}" in
  darwin) ALLOWED_BIN='^(rn-impeller|libimpeller\.dylib|hermesvm\.framework|libEGL\.dylib|libGLESv2\.dylib|LICENSE\.electron)$' ;;
  *)      ALLOWED_BIN='^(rn-impeller|libimpeller\.so|libhermesvm\.so)$' ;;
esac
STRAY_BIN="$(cd "${PKG}/bin" && ls -A | grep -vE "${ALLOWED_BIN}" || true)"
[ -z "$STRAY_BIN" ] || { echo "engine-build: FAIL — stray files in bin/:"; echo "$STRAY_BIN"; exit 1; }

# Prove the staged binary runs on its OWN libraries, not the build tree's. A
# missing rpath only shows up once the package leaves this machine, which is
# exactly the failure the consumer gate exists to prevent.
#
# ⛔ THE TOOL MUST EXIST, OR THIS ASSERTION IS VACUOUS.
# `ldd` is absent on macOS, so the original `$(ldd ... || true)` produced an
# empty string and the check passed having examined nothing. Each branch
# verifies its own tool is present first.
if [ "${PLATFORM}" = "darwin" ]; then
  command -v otool >/dev/null || { echo "engine-build: FAIL — otool not found; cannot verify linkage" >&2; exit 1; }
  # otool -L lists what the binary asks for. Anything pointing INTO the build
  # tree or at an absolute developer path would break on a consumer's machine;
  # everything we ship must be @rpath/@loader_path relative or a system library.
  BADLINK="$(cd "${PKG}/bin" && otool -L ./rn-impeller | tail -n +2 \
    | grep -vE '@(rpath|loader_path|executable_path)/' \
    | grep -vE '/usr/lib/|/System/Library/' || true)"
  [ -z "$BADLINK" ] || { echo "engine-build: FAIL — staged binary links non-relocatable paths:"; echo "$BADLINK"; exit 1; }
  # And the rpath itself must be @loader_path, not this machine's build tree.
  if otool -l "${PKG}/bin/rn-impeller" | grep -A2 LC_RPATH | grep -q 'engine/build'; then
    echo "engine-build: FAIL — staged binary still has build-tree rpath" >&2
    otool -l "${PKG}/bin/rn-impeller" | grep -A2 LC_RPATH >&2
    exit 1
  fi
else
  command -v ldd >/dev/null || { echo "engine-build: FAIL — ldd not found; cannot verify linkage" >&2; exit 1; }
  MISSING="$(cd "${PKG}/bin" && ldd ./rn-impeller | grep 'not found' || true)"
  [ -z "$MISSING" ] || { echo "engine-build: FAIL — staged binary has unresolved libs:"; echo "$MISSING"; exit 1; }
  # ...and prove it is genuinely $ORIGIN-relative rather than accidentally
  # resolving through the build tree that is still on this disk.
  if readelf -d "${PKG}/bin/rn-impeller" | grep -qE 'R(UN)?PATH.*engine/build'; then
    echo "engine-build: FAIL — staged binary still has build-tree rpath" >&2
    readelf -d "${PKG}/bin/rn-impeller" | grep -E 'R(UN)?PATH' >&2
    exit 1
  fi
fi

# ⛔ AND THE STAGED BINARY MUST ACTUALLY START.
# Everything above inspects the binary; none of it proves the loader can
# satisfy it. The darwin package passed every static check — no strays, no
# non-relocatable paths, correct @loader_path rpath — and then died instantly:
#
#   dyld: Library not loaded: @rpath/hermesvm.framework/Versions/0/hermesvm
#
# because Hermes' framework was staged as a flat file while the executable
# references it by PATH. A link-time check cannot see that; only running it
# can. So run it, from a directory that is NOT bin/, which also catches the
# `./libfoo.dylib` install-name class of bug in one move.
#
# --help is chosen deliberately: it exercises dyld's full load of every
# dependency and exits without needing a bundle, a display or a GPU.
echo "engine-build: launch check (dyld must resolve every dependency)"
LAUNCH_OUT="$(cd / && "${ROOT}/${PKG}/bin/rn-impeller" --help 2>&1 || true)"
case "${LAUNCH_OUT}" in
  *"Library not loaded"*|*"image not found"*|*"error while loading shared libraries"*|*"cannot open shared object"*)
    echo "engine-build: FAIL — the staged binary cannot start:" >&2
    echo "${LAUNCH_OUT}" | head -6 >&2
    exit 1 ;;
esac

# R3 size budget: <60 MB unpacked per platform. Measure, never assume.
UNPACKED_KB=$(du -sk "${PKG}/bin" | cut -f1)
echo "engine-build: unpacked payload = $((UNPACKED_KB / 1024)) MB"
if [ "${UNPACKED_KB}" -gt 61440 ]; then
  echo "engine-build: FAIL — payload exceeds the 60 MB budget (R3)" >&2
  exit 1
fi

cat > "${PKG}/package.json" <<JSON
{
  "name": "@react-native-impeller/engine-${TRIPLE}",
  "version": "${VERSION}",
  "description": "Prebuilt Impeller engine host for ${TRIPLE} (installed automatically by @react-native-impeller/core)",
  "license": "MIT",
  "files": ["bin", "README.md"],
  "publishConfig": {
    "access": "public"
  },
  "os": ["${PLATFORM}"],
  "cpu": ["${ARCH}"]
}
JSON

cat > "${PKG}/README.md" <<MD
# @react-native-impeller/engine-${TRIPLE}

Prebuilt engine binary for \`react-native-impeller\` on ${TRIPLE}.

Installed automatically as an optional dependency — do not depend on it directly.
Version is locked in step with \`react-native-impeller\`; the resolver refuses a
mismatch because the engine C ABI is not stable across versions.

Impeller SDK pin: \`$(cat engine/IMPELLER_SHA)\`
React Native (ReactCommon) pin: \`$(node -p "require('${ROOT}/engine/rn/node_modules/react-native/package.json').version")\`
MD

echo "engine-build: staged ${PKG} @ ${VERSION}"
