# Run by `cmake --install --component engine` on macOS, through
# install(SCRIPT) in engine/CMakeLists.txt, after the payload is copied into
# ${CMAKE_INSTALL_PREFIX}/bin. It makes that bin/ relocatable, so the engine
# runs from wherever npm unpacks it, and signs every Mach-O it changed.
#
# Inputs: CMAKE_INSTALL_PREFIX (set by cmake --install).

set(_bin "${CMAKE_INSTALL_PREFIX}/bin")

# Fails the install on a nonzero exit, with the command and its stderr. The
# old inline block ignored install_name_tool's exit code.
function(_stage_run)
  execute_process(COMMAND ${ARGN} RESULT_VARIABLE _rc ERROR_VARIABLE _err OUTPUT_QUIET)
  if(NOT _rc EQUAL 0)
    string(REPLACE ";" " " _cmd "${ARGN}")
    message(FATAL_ERROR "stage-darwin: `${_cmd}` failed (rc=${_rc}): ${_err}")
  endif()
endfunction()

# ⛔ HERMES SHIPS AS A PLAIN DYLIB, NOT AS hermesvm.framework.
# Hermes' CMake builds a versioned framework on macOS. Its Versions/Current,
# hermesvm and Resources entries are SYMLINKS, and `npm pack` drops symlinks
# without a warning. 0.1.0 shipped the framework that way. dyld still loaded
# Versions/0/hermesvm through @rpath, so the engine ran, but codesign of any
# .app that embedded it failed:
#
#   bundle format unrecognized, invalid, or unsuitable
#   In subcomponent: .../Contents/MacOS/hermesvm.framework
#
# A flat libhermesvm.dylib beside rn-impeller is what libimpeller and ANGLE
# already are. It survives npm pack, and an .app that embeds bin/ signs and
# passes `codesign --verify --deep --strict`. CMakeLists.txt installs the
# framework's binary under that name; this script repoints rn-impeller at it.
# tools/ci-engine-pack.sh checks the packed result.

# ⛔ REWRITE THE INSTALL NAMES, OR THE PACKAGE ONLY RUNS FROM ITS OWN bin/.
# ANGLE ships with install name `./libEGL.dylib` (Electron's convention,
# confirmed with `otool -D`), and the Impeller SDK ships `./libimpeller.dylib`
# the same way. dyld resolves those against the PROCESS WORKING DIRECTORY, so
# a consumer launching the engine from their app root would get "image not
# found" for a file sitting right next to the binary. The engine-build gate
# caught this on the first darwin link ("staged binary links non-relocatable
# paths: ./libimpeller.dylib"). Every shipped dylib gets its ID rewritten, and
# every reference inside the executable is repointed at @rpath.
#
# ⛔ @rpath, NOT @loader_path, FOR WHAT rn-impeller LOADS.
# An @loader_path/libfoo.dylib reference only ever looks beside rn-impeller.
# A standard .app keeps the executable in Contents/MacOS and its dylibs in
# Contents/Frameworks, so 0.1.0 aborted there (rc=134) and every consumer
# patched the signed binary with install_name_tool. @rpath names go through
# rn-impeller's LC_RPATH list, which CMakeLists.txt sets to @loader_path and
# @loader_path/../Frameworks: bin/ as npm unpacks it and MacOS + Frameworks
# both load, untouched. libGLESv2 -> libEGL stays @loader_path: the two ANGLE
# libraries always sit in the same directory, whichever one that is.
foreach(_lib libEGL.dylib libGLESv2.dylib libimpeller.dylib libhermesvm.dylib)
  _stage_run(install_name_tool -id "@rpath/${_lib}" "${_bin}/${_lib}")
endforeach()

# rn-impeller links Hermes by the framework's install name, which Hermes'
# build decides (today @rpath/hermesvm.framework/Versions/0/hermesvm). Read it
# from the binary rather than hardcoding it: install_name_tool -change is a
# silent no-op when the old name is absent, and the result would only fail at
# dyld on a consumer's machine.
execute_process(COMMAND otool -L "${_bin}/rn-impeller"
                OUTPUT_VARIABLE _deps RESULT_VARIABLE _rc)
if(NOT _rc EQUAL 0)
  message(FATAL_ERROR "stage-darwin: otool -L rn-impeller failed (rc=${_rc})")
endif()
string(REGEX MATCH "[^\t\n ]*hermesvm\\.framework/[^\t\n ]*" _hermes_ref "${_deps}")
if(NOT _hermes_ref)
  message(FATAL_ERROR
    "stage-darwin: rn-impeller has no hermesvm.framework reference to repoint. "
    "otool -L said:\n${_deps}")
endif()
_stage_run(install_name_tool
  -change "./libEGL.dylib"      "@rpath/libEGL.dylib"
  -change "./libGLESv2.dylib"   "@rpath/libGLESv2.dylib"
  -change "./libimpeller.dylib" "@rpath/libimpeller.dylib"
  -change "${_hermes_ref}"      "@rpath/libhermesvm.dylib"
  "${_bin}/rn-impeller")
# libGLESv2 references libEGL by the same relative name.
_stage_run(install_name_tool
  -change "./libEGL.dylib" "@loader_path/libEGL.dylib"
  "${_bin}/libGLESv2.dylib")

# Verify the result instead of trusting the -change calls: each one is a
# silent no-op when its old name is absent.
execute_process(COMMAND otool -L "${_bin}/rn-impeller" OUTPUT_VARIABLE _deps)
foreach(_lib libEGL.dylib libGLESv2.dylib libimpeller.dylib libhermesvm.dylib)
  if(NOT _deps MATCHES "@rpath/${_lib}")
    message(FATAL_ERROR
      "stage-darwin: rn-impeller does not load @rpath/${_lib}:\n${_deps}")
  endif()
endforeach()
if(_deps MATCHES "hermesvm\\.framework" OR _deps MATCHES "(^|[\t\n ])(\\./|@loader_path/)lib")
  message(FATAL_ERROR
    "stage-darwin: rn-impeller still loads a framework or a non-@rpath dylib:\n${_deps}")
endif()
execute_process(COMMAND otool -l "${_bin}/rn-impeller" OUTPUT_VARIABLE _lc)
foreach(_rp "@loader_path" "@loader_path/../Frameworks")
  string(REPLACE "." "\\." _rp_re "${_rp}")
  if(NOT _lc MATCHES "path ${_rp_re} \\(offset")
    message(FATAL_ERROR
      "stage-darwin: rn-impeller has no LC_RPATH ${_rp} (INSTALL_RPATH in "
      "engine/CMakeLists.txt). Without it the @rpath names above cannot load.")
  endif()
endforeach()

# ⛔ RE-SIGN, OR arm64 KILLS THE PROCESS WITH NO DIAGNOSTIC.
# Every install_name_tool write invalidates the Mach-O code signature. On
# Apple silicon a signature is mandatory: an unsigned or stale-signature image
# is refused by the kernel, and the process dies on SIGKILL (9) or
# `Abort trap: 6` with nothing on stderr. That looks the same as the
# relative-install-name crash above. cctools' install_name_tool re-signs
# ad-hoc by itself in most cases, which works on the build box and breaks on a
# toolchain bump, so sign explicitly. `-` is the ad-hoc identity, which is all
# a non-distributed CLI binary needs.
foreach(_m libEGL.dylib libGLESv2.dylib libimpeller.dylib libhermesvm.dylib rn-impeller)
  execute_process(COMMAND codesign --force --sign - "${_bin}/${_m}"
                  RESULT_VARIABLE _cs_rc ERROR_QUIET OUTPUT_QUIET)
  if(NOT _cs_rc EQUAL 0)
    message(FATAL_ERROR
      "codesign failed on ${_m} (rc=${_cs_rc}). Shipping an image with an "
      "install_name_tool-invalidated signature produces an unexplained "
      "Abort trap: 6 on every arm64 consumer.")
  endif()
endforeach()
