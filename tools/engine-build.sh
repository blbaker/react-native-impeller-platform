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
# ⛔ THE DEFAULT TRIPLE IS THE HOST'S, NOT "linux x64".
# This used to read `${1:-linux}` / `${2:-x64}`. The toolchain switch below keys
# off `uname -s`, so on a Mac an argument-less run COMPILED A CORRECT DARWIN
# BINARY AND STAGED IT INTO packages-engine/engine-linux-x64/ — announcing
# "configuring + compiling linux-x64 host" while writing an arm64 Mach-O, Mac
# dylibs and hermesvm.framework into the Linux package. Nothing downstream
# checks a staged binary's architecture, so the corruption is silent until
# `npm install` of the tarballs fails on a consumer gate and reads as a real
# gate failure. Measured 2026-09-03 on the macOS tester.
#
# Eleven call sites still pass a literal `linux x64` or default RNI_ENGINE_PKG
# to engine-linux-x64; those are separately wrong on a Mac, but the default here
# is what turns "gate can't run" into "gate poisons the package".
#
# Derived from node — the SAME source ci-triple.sh uses — so the two can't drift.
PLATFORM="${1:-$(node -p 'process.platform' 2>/dev/null)}"
ARCH="${2:-$(node -p 'process.arch' 2>/dev/null)}"
if [ -z "${PLATFORM}" ] || [ -z "${ARCH}" ]; then
  echo "engine-build: FAIL — no triple given and node is not on PATH to supply one." >&2
  echo "  Pass one explicitly (engine-build.sh linux x64) or load nvm:" >&2
  echo "    . \"\$HOME/.nvm/nvm.sh\"" >&2
  exit 1
fi
case "${PLATFORM}" in
  windows|win) PLATFORM=win32 ;;
esac
TRIPLE="${PLATFORM}-${ARCH}"
PKG="packages-engine/engine-${TRIPLE}"

# ⛔ A NATIVE COMPILE CANNOT CROSS-BUILD. Everything below this point compiles
# with the HOST toolchain, so a requested platform that disagrees with `uname`
# does not produce the requested package — it produces a host binary in the
# wrong directory. Refuse, loudly, instead of staging a lie. (win32 is exempt:
# it execs a staging script that copies prebuilt artefacts rather than compiling.)
case "$(uname -s)" in
  Darwin) HOST_PLATFORM=darwin ;;
  Linux)  HOST_PLATFORM=linux ;;
  *)      HOST_PLATFORM=unknown ;;
esac
if [ "${PLATFORM}" != "win32" ] && [ "${PLATFORM}" != "${HOST_PLATFORM}" ]; then
  echo "engine-build: FAIL — asked for '${PLATFORM}' on a '${HOST_PLATFORM}' host." >&2
  echo "  This script compiles natively; it cannot cross-build. Building anyway" >&2
  echo "  would stage a ${HOST_PLATFORM} binary into ${PKG}, which installs and" >&2
  echo "  then fails at exec with an unrelated-looking error." >&2
  echo "  Run it on a ${PLATFORM} host, or drop the argument to build for this one." >&2
  exit 1
fi
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

# GLFW backs the windowed host, which CMake builds by default (RNI_WITH_WINDOW).
# Fetch it the same way as the SDK and ANGLE above. Without this, a fresh clone
# or a cold CI cache fails in CMake with "GLFW not found", which is how CI on
# the public repo went red on its very first run.
if [ ! -f "engine/third_party/glfw/install/lib/libglfw3.a" ]; then
  bash tools/glfw-fetch.sh
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
# FP-22: an SDK rebuilt with this tree's patches (0003 context flags) lives in
# a real per-worktree dir, never in the shared impeller-sdk-custom*; it wins
# when present. RNI_IMPELLER_SDK_DIR set by the caller still overrides.
#
# ⛔ A CHECKOUT WITHOUT THAT SDK FETCHES IT; IT NEVER FALLS BACK TO STOCK.
# The fallback to the stock SDK was silent. It compiles and links, and then
# paints no underline and no letter spacing, so CI (which has no local SDK)
# built a different engine from every developer machine, and that is the
# engine a release would have published. tools/sdk-fetch-custom.sh downloads
# the prebuilt SDK for this tree's patches, or fails saying why.
# RNI_STOCK_IMPELLER_SDK=1 builds against the stock SDK on purpose.
if [ -z "${RNI_IMPELLER_SDK_DIR:-}" ]; then
  case "${PLATFORM}" in
    darwin) PARITY_SDK="engine/third_party/impeller-sdk-custom-parity-darwin" ;;
    *)      PARITY_SDK="engine/third_party/impeller-sdk-custom-parity" ;;
  esac
  if [ ! -f "${PARITY_SDK}/include/impeller.h" ]; then
    if [ "${RNI_STOCK_IMPELLER_SDK:-0}" = "1" ]; then
      echo "engine-build: RNI_STOCK_IMPELLER_SDK=1 — building against the STOCK SDK" \
           "(no text spacing, font features or decorations)"
    else
      bash tools/sdk-fetch-custom.sh "${TRIPLE}" "${PARITY_SDK}"
    fi
  fi
  [ ! -f "${PARITY_SDK}/include/impeller.h" ] || export RNI_IMPELLER_SDK_DIR="${PARITY_SDK}"
fi
echo "engine-build: Impeller SDK = ${RNI_IMPELLER_SDK_DIR:-stock}"
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

# ⛔ STRIP INVALIDATES THE CODE SIGNATURE. RE-SIGN, OR arm64 KILLS THE BINARY.
# The install step's install_name_tool rewrite leaves a valid ad-hoc signature
# behind, and then the strip above silently breaks it again -- so the verify
# further down fails on rn-impeller and ONLY on rn-impeller (the dylibs are
# never stripped). On Apple silicon an invalid signature is `Abort trap: 6`
# with no message, the exact symptom a bad install name produces, which is how
# this hid behind the install-name work instead of showing up as its own bug.
# Ad-hoc (`-s -`) matches what the toolchain already produces; this re-signs
# rather than skipping the strip because the size win is real and the fix is
# one line.
if [ "${PLATFORM}" = "darwin" ] && command -v codesign >/dev/null; then
  codesign --force -s - "${PKG}/bin/rn-impeller" >/dev/null 2>&1 \
    || { echo "engine-build: FAIL — could not re-sign rn-impeller after strip"; exit 1; }
fi

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
  # ⛔ CHECK EVERY MACH-O WE SHIP, NOT JUST THE EXECUTABLE.
  # The original form inspected ./rn-impeller alone. That is a hole: the dylibs
  # reference EACH OTHER (libGLESv2 -> libEGL), so a shipped library carrying a
  # `./libEGL.dylib` install name passes a binary-only check and then aborts at
  # runtime for the consumer. Reported from the mac 2026-09-03 after a raw
  # `cmake --build` was promoted directly, bypassing `cmake --install` and thus
  # bypassing the install_name_tool rewrite entirely: it ran from its own build
  # directory and died with `Abort trap: 6` from anywhere else. The rewrite
  # existing in CMakeLists is not evidence it RAN; only inspecting the staged
  # artifacts is.
  #
  # -D (the install ID) matters as much as -L (the dependencies): a library
  # whose own ID is relative poisons everything that links it later.
  BADLINK=""
  while IFS= read -r _macho; do
    _d="$(cd "${PKG}/bin" && otool -D "${_macho}" 2>/dev/null | tail -n +2 \
      | grep -vE '^@(rpath|loader_path|executable_path)/' | grep -v '^$' || true)"
    [ -z "$_d" ] || BADLINK="${BADLINK}${_macho} ID: ${_d}"$'\n'
    _l="$(cd "${PKG}/bin" && otool -L "${_macho}" 2>/dev/null | tail -n +2 \
      | grep -vE '@(rpath|loader_path|executable_path)/' \
      | grep -vE '/usr/lib/|/System/Library/' || true)"
    [ -z "$_l" ] || BADLINK="${BADLINK}${_macho} -> ${_l}"$'\n'
  done < <(cd "${PKG}/bin" && find . -type f \
             \( -name '*.dylib' -o -name 'rn-impeller' -o -name 'hermesvm' \) | sort)
  [ -z "$BADLINK" ] || { echo "engine-build: FAIL — staged Mach-O links non-relocatable paths:"; echo "$BADLINK"; exit 1; }

  # ⛔ AND EVERY ONE OF THEM MUST STILL BE VALIDLY SIGNED.
  # install_name_tool invalidates the signature it rewrites. An unsigned image
  # on arm64 is killed by the kernel with `Abort trap: 6` and no explanation —
  # the SAME symptom as the bad install name above, so a fix for one silently
  # masquerades as a fix for the other. Verify, do not assume the toolchain
  # re-signed for us.
  if command -v codesign >/dev/null; then
    BADSIG=""
    while IFS= read -r _macho; do
      (cd "${PKG}/bin" && codesign --verify "${_macho}" 2>/dev/null) \
        || BADSIG="${BADSIG}  ${_macho}"$'\n'
    done < <(cd "${PKG}/bin" && find . -type f \
               \( -name '*.dylib' -o -name 'rn-impeller' -o -name 'hermesvm' \) | sort)
    [ -z "$BADSIG" ] || { echo "engine-build: FAIL — staged Mach-O has an invalid/absent signature:"; echo "$BADSIG"; exit 1; }
  fi

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

# ⛔ AND THE STAGED FILE MUST BE THE ARCHITECTURE THE DIRECTORY NAME CLAIMS.
# Every check above this point is host-relative: run on a Mac, they lovingly
# verify a Mach-O's signature and @loader_path rpath — inside whatever directory
# they were pointed at, including engine-linux-x64/. That is exactly how an
# arm64 Mach-O got staged as the Linux engine on 2026-09-03 with all gates
# reporting success. The package name is a PROMISE to `resolve.js`; assert it
# against the file's real header, not against the variable that named the path.
case "${TRIPLE}" in
  linux-x64)    WANT_ARCH='ELF 64-bit.*x86-64' ;;
  linux-arm64)  WANT_ARCH='ELF 64-bit.*aarch64|ELF 64-bit.*ARM aarch64' ;;
  darwin-arm64) WANT_ARCH='Mach-O 64-bit.*arm64' ;;
  darwin-x64)   WANT_ARCH='Mach-O 64-bit.*x86_64' ;;
  *)            WANT_ARCH='' ;;
esac
if [ -n "${WANT_ARCH}" ]; then
  command -v file >/dev/null \
    || { echo "engine-build: FAIL — \`file\` not found; cannot verify staged architecture" >&2; exit 1; }
  ACTUAL="$(file -b "${PKG}/bin/rn-impeller")"
  if ! echo "${ACTUAL}" | grep -qE "${WANT_ARCH}"; then
    echo "engine-build: FAIL — ${PKG} is named for ${TRIPLE}, but the staged" >&2
    echo "  binary is not that architecture. This package would install cleanly" >&2
    echo "  on a ${PLATFORM} machine and fail at exec." >&2
    echo "    expected: ${WANT_ARCH}" >&2
    echo "    actual:   ${ACTUAL}" >&2
    exit 1
  fi
  echo "engine-build: arch check ....... OK (${TRIPLE})"
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
set +e
LAUNCH_OUT="$(cd / && "${ROOT}/${PKG}/bin/rn-impeller" --help 2>&1)"
LAUNCH_RC=$?
set -e
case "${LAUNCH_OUT}" in
  *"Library not loaded"*|*"image not found"*|*"error while loading shared libraries"*|*"cannot open shared object"*)
    echo "engine-build: FAIL — the staged binary cannot start:" >&2
    echo "${LAUNCH_OUT}" | head -6 >&2
    exit 1 ;;
esac
# ⛔ AND ITS EXIT CODE MUST BE CLEAN — a crash AFTER correct output is still a
# crash. The darwin engine printed a complete module manifest and then
# segfaulted in ~ReactHost (rc=139); every gate that piped the output saw the
# PIPE's status and called it green. Check the process, not the text.
if [ "${LAUNCH_RC}" -ne 0 ]; then
  echo "engine-build: FAIL — staged binary exited ${LAUNCH_RC} on --help" >&2
  echo "${LAUNCH_OUT}" | tail -6 >&2
  exit 1
fi

# R3 size budget: <60 MB unpacked per platform. Measure, never assume.
UNPACKED_KB=$(du -sk "${PKG}/bin" | cut -f1)
echo "engine-build: unpacked payload = $((UNPACKED_KB / 1024)) MB"
if [ "${UNPACKED_KB}" -gt 61440 ]; then
  echo "engine-build: FAIL — payload exceeds the 60 MB budget (R3)" >&2
  exit 1
fi

cat > "${PKG}/package.json" <<JSON
{
  "name": "@blbaker/react-native-impeller-platform-engine-${TRIPLE}",
  "version": "${VERSION}",
  "description": "Prebuilt Impeller engine host for ${TRIPLE} (installed automatically by react-native-impeller-platform)",
  "license": "MIT",
  "repository": {
    "type": "git",
    "url": "git+https://github.com/blbaker/react-native-impeller-platform.git",
    "directory": "packages-engine/engine-${TRIPLE}"
  },
  "homepage": "https://github.com/blbaker/react-native-impeller-platform#readme",
  "bugs": {
    "url": "https://github.com/blbaker/react-native-impeller-platform/issues"
  },
  "author": "Brandon Baker",
  "files": ["bin", "README.md"],
  "publishConfig": {
    "access": "public"
  },
  "os": ["${PLATFORM}"],
  "cpu": ["${ARCH}"]
}
JSON

cat > "${PKG}/README.md" <<MD
# @blbaker/react-native-impeller-platform-engine-${TRIPLE}

Prebuilt engine binary for \`react-native-impeller-platform\` on ${TRIPLE}.

Installed automatically as an optional dependency — do not depend on it directly.
Version is locked in step with \`react-native-impeller-platform\`; the resolver refuses a
mismatch because the engine C ABI is not stable across versions.

Impeller SDK pin: \`$(cat engine/IMPELLER_SHA)\`
React Native (ReactCommon) pin: \`$(node -p "require('${ROOT}/engine/rn/node_modules/react-native/package.json').version")\`
MD

echo "engine-build: staged ${PKG} @ ${VERSION}"
